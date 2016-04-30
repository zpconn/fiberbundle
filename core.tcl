
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
			# state - one of (RUN, WAIT, EXITING)
			#
			variable state "RUN"

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

		method append_to_mailbox {sender type content} {
			variable mailbox
			append mailbox [list $sender $type $content]
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

				thread::send -async $master_thread_id \
					[list $bundle_space_name relay_message $sender $receiver $type $content]
			}
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
	}
}

package provide fiberbundle-core 1.0

