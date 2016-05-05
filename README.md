fiberbundle
===========

fiberbundle is a library for massive multicore Erlang-style concurrency and parallelism in Tcl.

This library is heavily inspired by the tclfiber library, which includes many of the same ideas and implementation details but is completely single-threaded. fiberbundle was originally intended to be a fork of tclfiber, but I decided it made more sense to rewrite it from scratch so that the whole library could be designed for multithreading.

fiberbundle takes the fiber concept from tclfiber along with the core idea that a userspace fiber corresponds to a coroutine in Tcl, and it introduces the new notions of a bundle and bundle space in order to spread fibers uniformly across Tcl threads and available CPU cores.

The architecture is centralized and is not currently designed to span multiple nodes. While this prevents it from achieving true Erlang-style scale, it also drastically simplifies the design and implementation and eliminates entire classes of bugs.

It is currently a work in progress, with many planned features unimplemented. Current features:

1. Creation of up to millions of fibers as coroutines along with a cooperative scheduling algorithm.
2. Creation and management of multiple Tcl threads behind the scenes. Fibers are automatically distributed across threads. Fibers in different threads aren't aware of this and can easily communicate as if they were in the same thread.
3. Basic agent functionality (an agent is a fiber which stores state which can be concurrently accessed and modified by other fibers).
4. Basic worker pool functionality (mapping a lambda expression over a list of inputs with full parallelization; this is much lighter than using a thread pool and thus scales to massive lists better).

Planned features:

1. Much better error handling.
2. A full promise abstraction, implemented with fibers and agents, along with the ability to chain promises.
3. Support for monitoring fibers.
4. Better support for channels.

Here's an example of a rather silly and intentionally inefficient script that shows how easily the library can consume all available CPU resources (it achieves >3000% CPU usage on my machine):

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
	set lambda {{x} { return [fib $x] }}
	send logger info "Starting map!"
	set outputs [::fiberbundle::prelude::map $inputs $lambda]
	send logger info "Output: $outputs"

	wait_forever
}}
```

