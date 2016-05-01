
package require Tcl 8.6
package require Thread 
package require TclOO
package require fiberbundle-core

#
# fiberbundle is a library for massive multicore Erlang-style concurrency in Tcl.
#
# This library is heavily inspired by the tclfiber library, which includes many
# of the same ideas and implementation details but is completely single-threaded.
#
# fiberbundle takes the fiber concept from tclfiber along with the core idea that
# a userspace fiber corresponds to a coroutine in Tcl, and it introduces the new notions
# of a bundle and bundle space in order to spread fibers uniformly across Tcl threads
# and available CPU cores.
#

namespace eval ::fiberbundle {
	# 
	# bundle_space - a bundle space is a collection of bundles, each of which exists
	# in its own Tcl thread. A bundle space acts as an orchestrator for creating new
	# bundles, spawning fibers across threads, and facilitating message communication
	# between fibers in different bundles.
	#
	oo::class create bundle_space {
		constructor {} {
			#
			# bundles - maps a bundle ID (a nonnegative integer) to the ID of
			# the Tcl thread containing the associated bundle object.
			#
			variable bundles
			array set bundles {}

			#
			# fibers - maps the name of a fiber to the ID of the bundle containing it.
			# This is aware of all fibers across all bundles contained in this bundle space.
			#
			variable fibers
			array set fibers {}

			variable next_unique_bundle_id 0
			variable round_robin_spawn_id 0
		}

		#
		# spawn_bundle - spawns a new Tcl thread that contains a new bundle.
		#
		# Returns a tuple (a list of two elements) with the bundle ID and thread ID.
		#
		method spawn_bundle {} {
			variable bundles
			variable next_unique_bundle_id

			set bundle_id $next_unique_bundle_id
			incr next_unique_bundle_id

			set master_thread_id [thread::id]
			set thread_id [thread::create [format {
				package require fiberbundle-core
				set ::bundle [::fiberbundle::core::bundle new %s %s %s]

				namespace eval ::fiberbundle::coroutines {}

				proc spawn_local_fiber {name lambda args} {
					$::bundle spawn_fiber $name $lambda {*}$args
				}

				proc receive_relayed_message {sender receiver type content} {
					$::bundle receive_relayed_message $sender $receiver $type $content
				}

				proc receive {mvar script} {
					$::bundle receive_proxy $mvar $script
				}

				proc send {receiver type content} {
					$::bundle send_proxy $receiver $type $content
				}

				proc loop {script} {
					while {1} {
						uplevel 1 $script
					}
				}

				$::bundle run_scheduler
				thread::wait
			} $bundle_id $master_thread_id [self]]]

			set bundles($bundle_id) $thread_id
			return [list $bundle_id $thread_id]
		}

		#
		# spawn_bundles - spawns multiple bundles, each in a new thread. 
		#
		method spawn_bundles {n} {
			if {$n <= 0} {
				return
			}

			my spawn_bundle
			tailcall my spawn_bundles [expr {$n - 1}]
		}

		#
		# spawn_fiber - spawns a new fiber in an available bundle.
		#
		method spawn_fiber {name lambda args} {
			variable bundles
			variable fibers
			variable round_robin_spawn_id

			# Determine which bundle to spawn the fiber in.
			set bundle_id $round_robin_spawn_id
			incr round_robin_spawn_id
			if {$round_robin_spawn_id >= [llength [array names bundles]]} {
				set round_robin_spawn_id 0
			}

			# Send a message to the appropriate Tcl thread indicating that
			# a new fiber should be created inside its respective bundle.
			set thread_id $bundles($bundle_id)
			thread::send -async $thread_id [list spawn_local_fiber $name $lambda {*}$args]

			# Bookkeeping.
			set fibers($name) $bundle_id

			#
			# TODO:
			#
			# - Name conflicts.
			# - Handle failure to create the fiber in the thread.
			#
		}

		#
		# relay_message - invoked asynchronously by a bundle in a Tcl thread when it needs to send
		# a message from a fiber it contains to a fiber in a different bundle.
		#
		method relay_message {sender receiver type content} {
			variable fibers
			variable bundles

			# Fetch the bundle ID and thread ID of the receiving fiber.
			set bundle_id $fibers($receiver)
			set thread_id $bundles($bundle_id)

			# Send a message to the appropriate Tcl thread.
			thread::send -async $thread_id [list receive_relayed_message $sender $receiver $type $content]
		}

		method spawn_test_fibers {n} {
			for {set i 0} {$i < $n} {incr i} {
				my spawn_fiber test_${i} {{} {
					loop {
						receive msg {
							send logger info "I was sent a message from $msg(sender)!"
						}
					}
				}} 
			}
		}
	}
}

package provide fiberbundle 1.0

