fiberbundle
===========

fiberbundle is a library for massive multicore Erlang-style concurrency and parallelism in Tcl.

This library is heavily inspired by the tclfiber library, which includes many of the same ideas and implementation details but is completely single-threaded. 

fiberbundle takes the fiber concept from tclfiber along with the core idea that a userspace fiber corresponds to a coroutine in Tcl, and it introduces the new notions of a bundle and bundle space in order to spread fibers uniformly across Tcl threads and available CPU cores.

The architecture is centralized and is not currently designed to span multiple nodes. While this prevents it from achieving true Erlang-style scale, it also drastically simplifies the design and implementation and eliminates entire classes of bugs.

It is currently a work in progress. Current features:

1. Creation of up to hundreds of thousands of fibers as coroutines along with a cooperative scheduling algorithm.
2. Creation and management of multiple Tcl threads behind the scenes. Fibers are automatically distributed across threads. Fibers in different threads aren't aware of this and can easily communicate as if they were in the same thread.
3. Synchronous and asynchronous agents (an agent is a fiber which stores state which can be concurrently accessed and modified by other fibers).
4. Basic worker pool functionality.
5. Fast immutable closures that can be passed to fibers and other threads.
6. Full support for nested receive loops. This is achieved while keeping the core scheduler from ever being reentrant.
7. Message type and sender whitelists for solving complex concurrency issues with nested receive loops.

As a very basic use case, the library provides easy-to-use parallelism and worker pools. Here's an example of a rather silly and intentionally inefficient script that shows how easily the library can consume all available CPU resources (it achieves >3000% CPU usage on my machine):

```tcl
package require fiberbundle
package require fiberbundle-prelude

# Any procs defined here will be available in any fiber and in any thread.
set shared_code_buffer {
	proc fib {n} {
		if {$n <= 1} {
			return 1
		}

		return [expr {[fib [expr {$n-1}]] + [fib [expr {$n-2}]]}]
	}
}

# The universe oversees all the different threads behind the scenes.
set ::universe [::fiberbundle::universe new $shared_code_buffer]

# Inflation causes the universe to create one thread and one bundle per
# available CPU core.
$::universe inflate

# To create a fiber and run it, we just need to supply a name and a lambda
# expression for it to execute.
$::universe spawn_fiber main {{} {
	# Create an asynchronous logger which writes to a file.
	::fiberbundle::prelude::spawn_logger test.log

	set inputs [list]
	set range 100
	for {set i 0} {$i < $range} {incr i} {
		lappend inputs $i
	}

    # Waste as many CPU cores as possible computing Fibonacci numbers.
    # Note that the standard map function used here performs the computations in parallel
    # in multiple fibers, but it blocks the current fiber until all the calculations
    # complete and return results.

	set lambda {{x} { return [fib $x] }}
	send logger info "Starting map!"
	set outputs [::fiberbundle::prelude::map $inputs $lambda]
	send logger info "Output: $outputs"

	wait_forever
}}
```

But you can do this without fiberbundle just using thread pools. fiberbundle distinguishes itself by providing both parallelism *and* powerful concurrency primitives.

The prelude supports agent fibers for the creation and management of state. An agent fiber is a fiber whose sole purpose is to hold some state. Other fibers can concurrently retrieve or modify the state by sending messages to the agent. The prelude has some functions that make such communication simpler, hiding its asynchronous nature from the user if desired. A trivial example:

```tcl
# This should be inside a fiber.

# Creates a stateful agent fiber named `counter`.
::fiberbundle::prelude::spawn_simple_agent counter 1

# Updates the state in the `counter` agent from 1 to 2.
# agent_put is synchronous and waits for a success signal
# from the agent before proceeding.
::fiberbundle::prelude::agent_put counter 2

# Agent state can also be modified using a lambda expression.
::fiberbundle::prelude::agent_update counter {{x} { return [expr {$x * $x}] }}

# Communicates with the agent fiber via messages to retrieve
# its state. Like agent_put, agent_get converts asynchronous
# communication into a function that blocks until a result
# is obtained.
set count [::fiberbundle::prelude::agent_get counter]
send logger info "The current count is $count!"
```

The advantage of agents is that they provide shared state that is easily accessible from any fiber using simple message passing semantics.

Here's an example program that reads input lines of data from a massive TSV file. Each line contains several fields, including an ID (which may be shared across multiple lines), a latitude, and a longitude. This script stores all lat/lon pairs seen for each ID in a separate agent fiber.

It demonstrates some of the more advanced features of the library, including message type and sender whitelists in the receive loop, fast immutable closures that can be passed to a fiber in a potentially different thread, yielding a long-running computation in a fiber while keeping the fiber alive in the core scheduler, and optimizations like ensuring that the `iterator` fiber is spawned in the same bundle as the `processor` fiber to reduce the number of `thread::send -async` calls that the library will have to perform for routing the input messages to the `processor`.

```tcl
package require fiberbundle
package require fiberbundle-prelude

set ::universe [::fiberbundle::universe new]

proc main {{argv ""}} {
	$::universe inflate

	$::universe spawn_fiber iterator {{} {
		::fiberbundle::prelude::spawn_logger out.log

		spawn_fiber_in_specific_bundle processor {{} {
			set ids [dict create]
			set msg_count 0
			set fiber_count 0
			set last_clock [clock clicks -milliseconds]

			receive_forever msg {
				switch $msg(type) {
					line {
						set line $msg(content)
						incr msg_count

						if {[clock clicks -milliseconds] - $last_clock >= 1000} {
							send logger info "$msg_count messages in the last second."
							set msg_count 0
							set last_clock [clock clicks -milliseconds]
						}

						if {[catch {
							array set d [split $line \t]

							set id $d(id)
							set lat $d(lat)
							set lon $d(lon)

							if {[dict exists $ids $id]} {
								::fiberbundle::prelude::async_agent_update_closure $id \
									[::fiberbundle::prelude::fast_closure {lat lon} {ps} {
										return [concat $ps [list [list $lat $lon]]]
									}]
							} else {
								dict set ids $id 1
								::fiberbundle::prelude::spawn_simple_agent $id [list [list $lat $lon]]
								incr fiber_count
								if {$fiber_count % 1000 == 0} {
									send logger info "spawned $fiber_count fibers so far"
								}
							}
						} catchResult] == 1} {
							send logger error $catchResult
						}
					}
				}
			} [dict create type_whitelist [list line] sender_whitelist [list iterator] batch 2000]
		}} 0

		set fn "input.tsv"
		set fh [open $fn r]
		set idx 0

		while {[gets $fh line] >= 0} {
			incr idx
			send processor line $line
			if {$idx % 100 == 0} {
				yield_alive
			}
		}

		close $fh
	}}

	vwait die
}

```
