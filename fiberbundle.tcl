
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
		constructor {{_shared_code_buffer {}}} {
			variable shared_code_buffer
			set shared_code_buffer $_shared_code_buffer

			variable thread_id
			set thread_id [my spawn_master_thread]
		}

		method spawn_master_thread {} {
			return [thread::create {
				package require fiberbundle
				package require Thread
				package require TclOO

				set ::bundle_space [::fiberbundle::bundle_space new]

				proc spawn_bundles {n shared_code_buffer} {
					$::bundle_space spawn_bundles $n $shared_code_buffer
				}

				proc spawn_fiber {name lambda args} {
					$::bundle_space spawn_fiber $name $lambda {*}$args
				}

				proc spawn_fiber_in_specific_bundle {name lambda bundle_id args} {
					$::bundle_space spawn_fiber_in_specific_bundle $name $lambda $bundle_id {*}$args
				}

				proc relay_message {sender receiver type {content {}}} {
					$::bundle_space relay_message $sender $receiver $type $content
				}

				proc spawn_test_fibers {n} {
					$::bundle_space spawn_test_fibers $n
				}

				proc inflate {shared_code_buffer fallback_count} {
					$::bundle_space inflate $shared_code_buffer $fallback_count
				}

				thread::wait
			}]
		}

		method spawn_bundles {n} {
			variable thread_id
			variable shared_code_buffer

			thread::send -async $thread_id [list spawn_bundles $n $shared_code_buffer]
		}

		method spawn_fiber {name lambda args} {
			variable thread_id
			thread::send -async $thread_id [list spawn_fiber $name $lambda {*}$args]
		}

		method relay_message {sender receiver type {content {}}} {
			variable thread_id
			thread::send -async $thread_id [list relay_message $sender $receiver $type $content]
		}

		method inflate {{fallback_count 32}} {
			variable thread_id
			variable shared_code_buffer

			thread::send -async $thread_id [list inflate $shared_code_buffer $fallback_count]
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
		method spawn_bundle {shared_code_buffer} {
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

				set shared_code_buffer %s
				if {$shared_code_buffer != {}} {
					eval $shared_code_buffer
				}

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

				proc spawn_fiber_in_specific_bundle {name lambda bundle_id args} {
					thread::send -async [$::bundle master_thread_id] \
						[list spawn_fiber_in_specific_bundle $name $lambda $bundle_id {*}$args]
				}

				proc receive_relayed_message {sender receiver type content} {
					$::bundle receive_relayed_message $sender $receiver $type $content
				}

				proc receive_forever {mvar script {opts {}}} {
					dict set opts forever 1
					$::bundle receive_proxy $mvar $script $opts
				}

				proc receive_once {mvar script {opts {}}} {
					dict set opts forever 0
					$::bundle receive_proxy $mvar $script $opts
				}

				proc send {receiver type args} {
					if {[llength $args] == 1} {
						set args [lindex $args 0]
					}

					$::bundle send_proxy $receiver $type $args
				}

				proc current_fiber {} {
					return [$::bundle current_fiber]
				}

				proc new_pid {} {
					return [$::bundle new_pid]
				}

				#
				# loop - a helper function which invokes the provided script
				# repeatedly in an infinite loop.
				#
				proc loop {script} {
					while {1} {
						uplevel 1 $script
					}
				}

				#
				# wait_forever - causes the invoking fiber to simply wait forever
				# without ever exiting. It will no longer be able to respond to
				# messages, and its execution will never proceed beyond the call
				# to this function.
				#
				proc wait_forever {} {
					# We can efficiently wait forever by repeatedly yielding.
					#
					# After the first yield, this fiber will never be woken up
					# again by the scheduler unless it receives a message. Thus
					# this is a lot more efficient than doing something like 
					# invoking `receive_forever` with empty whitelists, since
					# `receive` is a somewhat expensive operation, especially with
					# whitelists provided.
					while {1} {
						yield
					}
				}

				#
				# yield_alive - this should be used to temporarily suspend a long-running
				# computation in a fiber which is not waiting on any messages.
				#
				# By default, the scheduler will only ever resume fibers that have
				# yielded and have pending messages. This yields the current fiber but
				# also tells the scheduler that this fiber should still be resumed
				# again in the future even if it has no pending messages.
				#
				proc yield_alive {} {
					# We want to yield the current coroutine, but we want to
					# keep the scheduler alive and make sure that this coroutine
					# will be executed again as soon as possible after the rest
					# have been given some time.

					$::bundle mark_current_fiber_ready
					set ::fiberbundle::core::dispatcher_running 1
					yield
				}

				$::bundle run_scheduler
				thread::wait
			} $bundle_id $master_thread_id [self] "\{$shared_code_buffer\}"]]

			set bundles($bundle_id) $thread_id
			return [list $bundle_id $thread_id]
		}

		#
		# spawn_bundles - spawns multiple bundles, each in a new thread. 
		#
		method spawn_bundles {n shared_code_buffer} {
			for {set i 0} {$i < $n} {incr i} {
				my spawn_bundle $shared_code_buffer
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
		method inflate {shared_code_buffer fallback_count} {
			set num_cores [my num_cpus]
			if {$num_cores <= 0} {
				set num_cores $fallback_count
			}

			my spawn_bundles $num_cores $shared_code_buffer
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
		# spawn_fiber_in_specific_bundle - spawns a new fiber in the bundle specified
		# by the provided bundle ID.
		#
		# Generally this should be used sparingly, but it makes sense to use if you know
		# that two fibers are going to be communicating via messages with very high
		# throughput. Making sure they're in the same bundle eliminates the need for every
		# such message to be routed through different threads and thus can be a pretty
		# big performance boost.
		#
		method spawn_fiber_in_specific_bundle {name lambda bundle_id args} {
			variable bundles
			variable fibers

			set thread_id $bundles($bundle_id)
			thread::send -async $thread_id [list spawn_local_fiber $name $lambda {*}$args]
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

