
package require Tcl 8.6
package require Thread 
package require TclOO

namespace eval ::fiberbundle::core {

	#
	# dispatcher_running - if the dispatcher is sleeping, it can be reactivated
	# by setting this variable.
	#
	variable dispatcher_running

	#
	# fiber - a fiber is a lightweight userspace green thread. Fibers do not
	# share memory or state and communicate with each other exclusively via
	# message passing. They are scheduled cooperatively, not preemptively.
	#
	oo::class create fiber {
		constructor {_coroutine_name _bundle_id} {
			# 
			# mailbox - list of pending messages for the fiber to process.
			#
			variable mailbox [list]

			#
			# state - one of (RUNNING, WAITING, EXITING)
			#
			variable state "RUNNING"

			#
			# coroutine_name - the fully qualified name of the coroutine
			# which represents this fiber.
			#
			variable coroutine_name $_coroutine_name

			#
			# bundleID - the ID of the parent bundle of this fiber. Assumes
			# the value -1 initially before membership in a bundle is established.
			# Afterwards is a nonnegative integer.
			#
			variable bundle_id $_bundle_id
		}

		method coroutine_name {} {
			variable coroutine_name
			return $coroutine_name
		}

		method mailbox {} {
			variable mailbox
			return $mailbox
		}

		method append_to_mailbox {sender type content} {
			variable mailbox
			lappend mailbox [list $sender $type $content]
		}

		method pop_message {} {
			variable mailbox
			
			if {[llength $mailbox] > 0} {
				set message [lindex $mailbox 0]
				set mailbox [lrange $mailbox 1 end]
				return $message
			}

			return ""
		}

		method set_state {new_state} {
			variable state
			set state $new_state
		}

		method wakeup {} {
			variable state
			variable dispatcher_running

			if {[string is false -strict $::fiberbundle::core::dispatcher_running]} {
				# The dispatcher is sleeping. Simply wake it up.
				set ::fiberbundle::core::dispatcher_running 1
			}
		}
	}

	#
	# bundle - a bundle is a collection of fibers and an associated scheduler for 
	# orchestrating their cooperative execution. One typically has one bundle per
	# Tcl thread.
	#
	oo::class create bundle {
		constructor {_bundle_id _master_thread_id _bundle_space_name} {
			#
			# fibers - maps the name of a fiber to a fiber object.
			# This is only aware of fibers contained in this bundle.
			#
			variable fibers
			array set fibers {}

			#
			# coroutine_names - maps the name of a coroutine to the name of
			# the corresponding fiber.
			#
			variable coroutine_names
			array set coroutine_names {}

			#
			# ready - a dict used to store only the names of fibers that are
			# ready for message delivery and have at least one pending message
			# to process.
			#
			variable ready [dict create]

			#
			# bundle_id - the ID of this bundle as it exists in its ambient bundle space.
			#
			variable bundle_id $_bundle_id

			#
			# master_thread_id - the ID of the master thread.
			#
			variable master_thread_id $_master_thread_id

			#
			# bundle_space_name - the name of the bundle space in the master thread
			# which this bundle belongs to.
			#
			variable bundle_space_name $_bundle_space_name
		}

		method spawn_fiber {name lambda args} {
			variable fibers
			variable bundle_id
			variable coroutine_names
			variable ready

			set coroutine_name ::fiberbundle::coroutines::$name
			set fiber [::fiberbundle::core::fiber new $coroutine_name $bundle_id]
			set fibers($name) $fiber
			dict unset ready $name
			set coroutine_names($coroutine_name) $name

			coroutine ::fiberbundle::coroutines::$name apply $lambda {*}$args
		}

		#
		# run_scheduler - once invoked, this function never exits.
		#
		# It runs fibers that are in a ready state until all fibers are
		# blocked or have no more work to do. Then it sleeps until it's
		# woken up again.
		#
		# For simplicity, one should never invoke this function directly
		# outside of this library's implementation.
		#
		method run_scheduler {} {
			variable fibers
			variable ready

			set ::fiberbundle::core::dispatcher_running 1

			while {1} {
				# We make a round-robin pass over active fibers until
				# none are active any longer.

				while {[dict size $ready]} {
					foreach fiber_name [dict keys $ready] {
						set fiber $fibers($fiber_name)
						[$fiber coroutine_name]
					}
				}

				# At this point all fibers are blocked. Relinquish control
				# to the Tcl event loop.

				set ::fiberbundle::core::dispatcher_running 0
				vwait ::fiberbundle::core::dispatcher_running
			}
		}

		#
		# send_message - this orchestrates the sending of a message from one
		# fiber to another. If both fibers are local to this bundle, then the
		# entire transfer can be handled here. Otherwise the message must be
		# relayed back to the controlling bundle space in the master thread,
		# which will then route it to the appropriate fiber in another bundle.
		#
		method send_message {sender receiver type content} {
			variable fibers
			variable ready
			variable master_thread_id
			variable bundle_space_name

			# The sender is always local to this bundle. However, the receiver
			# may not be.

			if {[info exists fibers($receiver)]} {
				# The receiver is in this bundle, so we can orchestrate this message
				# transfer locally.

				set fiber $fibers($receiver)
				$fiber append_to_mailbox $sender $type $content
				$fiber wakeup
				dict set ready $receiver 1
			} else {
				# The receiver is remote, so we need to relay the message back to the
				# master thread to handle the transfer.

				set cmd [list $bundle_space_name relay_message $sender $receiver $type $content]
				thread::send -async $master_thread_id $cmd
			}
		}

		method send_proxy {receiver type content} {
			variable coroutine_names

			set current_coroutine [info coroutine]
			if {$current_coroutine == ""} {
				return
			}

			set sender_name $coroutine_names($current_coroutine)
			my send_message $sender_name $receiver $type $content
		}

		#
		# receive_relayed_message - this is invoked by the controlling bundle space 
		# whenever a fiber from another bundle has sent a message to a fiber in
		# this bundle.
		#
		method receive_relayed_message {sender receiver type content} {
			variable fibers
			variable ready

			# The sender is remote from this bundle, but the receiver is local.
			set fiber $fibers($receiver)
			$fiber append_to_mailbox $sender $type $content
			$fiber wakeup
			dict set ready $receiver 1
		}

		#
		# receive_proxy - a fiber in this bundle can invoke this function directly
		# if it knows the identity of this bundle. Typically, the fiber's containing
		# thread will contain a wrapper proc around this function which should be
		# invoked instead.
		#
		# If the invoking fiber has a queued message in its mailbox, then this will 
		# execute the provided script. If no message is queued, then this will cause
		# the fiber to yield until a message is available.
		#
		method receive_proxy {mvar script} {
			variable coroutine_names
			variable fibers
			variable ready

			# Determine the identity of the invoking fiber.
			set current_coroutine [info coroutine]

			if {$current_coroutine == ""} {
				# This has been invoked outside of a fiber, where it has no meaning.
				return
			}

			set fiber_name $coroutine_names($current_coroutine)
			set fiber $fibers($fiber_name)

			while {1} {
				set mail [$fiber mailbox]

				if {[llength $mail] == 0} {
					# There are no pending messages. Wait for one.
					$fiber set_state WAITING
					dict unset ready $fiber_name
					yield
				} else {
					# There's a pending message. Invoke the provided script.
					set message [$fiber pop_message]

					upvar 2 $mvar shadow
					set shadow(sender) [lindex $message 0]
					set shadow(type) [lindex $message 1]
					set shadow(content) [lindex $message 2]

					$fiber set_state RUNNING
					uplevel 2 $script
				}
			}
		}
	}
}

package provide fiberbundle-core 1.0

