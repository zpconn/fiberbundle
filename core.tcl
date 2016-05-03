
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

		#
		# coroutine_name - fetches the name of the coroutine which implements this fiber.
		#
		method coroutine_name {} {
			variable coroutine_name
			return $coroutine_name
		}

		#
		# mailbox - fetches the entire mailbox of pending messages for this fiber.
		#
		method mailbox {} {
			variable mailbox
			return $mailbox
		}

		#
		# append_to_mailbox - appends a message to the end of the mailbox queue.
		#
		method append_to_mailbox {sender type content} {
			variable mailbox
			lappend mailbox [list $sender $type $content]
		}

		#
		# pop_message - removes the next message from this fiber's mailbox queue and
		# returns it.
		#
		method pop_message {} {
			variable mailbox
			
			if {[llength $mailbox] > 0} {
				set message [lindex $mailbox 0]
				set mailbox [lrange $mailbox 1 end]
				return $message
			}

			return ""
		}

		#
		# set_state - sets the state of this fiber.
		#
		method set_state {new_state} {
			variable state
			set state $new_state
		}

		#
		# wakeup - wakes up the scheduler so that any pending messages for this fiber
		# might get processed.
		#
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

			#
			# scheduler_invocations - counts the number of times the scheduler has been
			# invoked. This is used to prevent nested schedulers from existing.
			#
			variable scheduler_invocations 0
		}

		#
		# spawn_fiber - spawns a new fiber as a coroutine in this bundle.
		# The coroutine executes the provided lambda expression evaluated
		# on any optional arguments supplied.
		#
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
		# By design, the scheduler should only ever be invoked a single
		# time. In general, it should never be manually invoked by a user
		# of fiberbundle.
		#
		method run_scheduler {} {
			variable fibers
			variable ready
			variable scheduler_invocations

			incr scheduler_invocations
			if {$scheduler_invocations > 1} {
				# This should never be invoked more than once per bundle/thread.
				# It is always an error to do so, as the scheduler once invoked
				# is designed to run forever.
				return
			}

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
		# create_callback - this creates a callback function in a special namespace
		# in the Tcl thread containing this bundle. When the callback is invoked,
		# it sends a message with its arguments to the specified recipient fiber.
		#
		# The sender of the message is marked as the name of the callback function. Note
		# that this is a minor abuse since the callback technically does not exist
		# in a fiber.
		#
		# The type of the message is marked as 'callback'.
		#
		method create_callback {name receiver} {
			set bundle_obj [self object]

			namespace eval ::fiberbundle::callbacks {
				proc $name {args} {
					$bundle_obj send_message $name $receiver callback {*}$args
				}
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

		#
		# send_proxy - this acts as a proxy to send_message. When invoked by a fiber, this falls back
		# to send_message to send a message from the invoking fiber to the specified recipient.
		# The identity of the sender is automatically deduced.
		#
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
		# current_fiber - determines the identity of the current fiber and returns
		# its name.
		#
		# Returns the empty string if this has not been invoked from within a coroutine.
		#
		method current_fiber {} {
			variable coroutine_names

			set current_coroutine [info coroutine]

			if {$current_coroutine == ""} {
				# This has been invoked outside of a fiber, where it has no meaning.
				return ""
			}

			return $coroutine_names($current_coroutine)
		}

		#
		# receive_proxy - if the invoking fiber has a queued message in its mailbox, then this will 
		# execute the provided script. If no message is queued, then this will cause
		# the fiber to yield until a message is available.
		#
		# If 'forever' is set to true, then this will yield repeatedly. If 'forever' is set to false,
		# then this function will exit as soon as exactly one message has been received and
		# processed.
		#
		method receive_proxy {mvar script {forever 1}} {
			variable coroutine_names
			variable fibers
			variable ready

			set fiber_name [my current_fiber]
			set fiber $fibers($fiber_name)

			while {1} {
				set message [$fiber pop_message]

				if {$message == ""} {
					# There are no pending messages. Wait for one.
					$fiber set_state WAITING
					dict unset ready $fiber_name
					yield
				} else {
					# There's a pending message. Invoke the provided script.
					upvar 2 $mvar shadow
					set shadow(sender) [lindex $message 0]
					set shadow(type) [lindex $message 1]
					set shadow(content) [lindex $message 2]

					$fiber set_state RUNNING
					uplevel 2 $script

					if {!$forever} {
						# Before breaking out of the loop, we need to
						# determine if there are any remaining messages.

						set remaining_mail [$fiber mailbox]
						if {[llength $remaining_mail] == 0} {
							# We keep the state as RUNNING, since the
							# fiber will continue to execute. However,
							# we remove this fiber from the ready dict,
							# since it has no pending messages and thus
							# doesn't yet need to be rescheduled.

							dict unset ready $fiber_name
						}

						break
					}
				}
			}
		}
	}
}

package provide fiberbundle-core 1.0

