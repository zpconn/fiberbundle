
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
	# universe - a universe creates a thread to contain a bundle space and creates an external
	# interface to said bundle space. The advantage is that the new thread can keep
	# its event loop awake all the time by invoking thread::wait.
	#
	oo::class create universe {
		constructor {} {
			variable thread_id
			set thread_id [my spawn_master_thread]
		}

		method spawn_master_thread {} {
			return [thread::create {
				package require fiberbundle
				package require Thread
				package require TclOO

				set ::universe [::fiberbundle::bundle_space new]

				proc spawn_bundles {n} {
					$::universe spawn_bundles $n
				}

				proc spawn_fiber {name lambda args} {
					$::universe spawn_fiber $name $lambda {*}$args
				}

				proc relay_message {sender receiver type {content {}}} {
					$::universe relay_message $sender $receiver $type $content
				}

				proc spawn_test_fibers {n} {
					$::universe spawn_test_fibers $n
				}

				proc inflate {fallbackCount} {
					$::universe inflate $fallbackCount
				}

				thread::wait
			}]
		}

		method spawn_bundles {n} {
			variable thread_id
			thread::send -async $thread_id [list spawn_bundles $n]
		}

		method spawn_fiber {name lambda args} {
			variable thread_id
			thread::send -async $thread_id [list spawn_fiber $name $lambda {*}$args]
		}

		method relay_message {sender receiver type {content {}}} {
			variable thread_id
			thread::send -async $thread_id [list relay_message $sender $receiver $type $content]
		}

		method inflate {{fallbackCount 32}} {
			variable thread_id
			thread::send -async $thread_id [list inflate $fallbackCount]
		}
	}

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
				package require fiberbundle-prelude

				set ::bundle [::fiberbundle::core::bundle new %s %s %s]

				namespace eval ::fiberbundle::coroutines {}

				#
				# spawn_local_fiber - spawns a fiber in *this* bundle.
				#
				proc spawn_local_fiber {name lambda args} {
					$::bundle spawn_fiber $name $lambda {*}$args
				}

				#
				# spawn_fiber - spawns a fiber in any bundle by communicating
				# with the controlling bundle space.
				#
				proc spawn_fiber {name lambda args} {
					thread::send -async [$::bundle master_thread_id] \
						[list spawn_fiber $name $lambda {*}$args]
				}

				proc receive_relayed_message {sender receiver type content} {
					$::bundle receive_relayed_message $sender $receiver $type $content
				}

				proc receive_forever {mvar script} {
					$::bundle receive_proxy $mvar $script
				}

				proc receive_once {mvar script} {
					$::bundle receive_proxy $mvar $script 0
				}

				proc send {receiver type args} {
					$::bundle send_proxy $receiver $type $args
				}

				proc current_fiber {} {
					return [$::bundle current_fiber]
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
			for {set i 0} {$i < $n} {incr i} {
				my spawn_bundle
			}
		}

		#
		# num_cpus - attempts to automatically detect the number of available
		# CPU cores. This currently only officially supports FreeBSD.
		#
		# Returns -1 on failure.
		#
		method num_cpus {} {
			if {![catch {exec sysctl -n "hw.ncpu"} cores]} {
				if {[string is integer -strict $cores] && \
			        $cores >= 1} {
					return $cores
				}
			}

			return -1
		}

		#
		# inflate - spawns one bundle per available CPU core. If the number of cores
		# can't be detected automatically, then this uses the provided default number
		# of bundles to spawn.
		#
		method inflate {{fallback_count 32}} {
			set num_cores [my num_cpus]
			if {$num_cores <= 0} {
				set num_cores $fallback_count
			}

			my spawn_bundles $num_cores
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
	}
}

package provide fiberbundle 1.0

