fiberbundle
===========

fiberbundle is a library for massive multicore Erlang-style concurrency in Tcl.

This library is heavily inspired by the tclfiber library, which includes many of the same ideas and implementation details but is completely single-threaded. fiberbundle was originally intended to be a fork of tclfiber, but I decided it made more sense to rewrite it from scratch so that the whole library could be designed for multithreading.

fiberbundle takes the fiber concept from tclfiber along with the core idea that a userspace fiber corresponds to a coroutine in Tcl, and it introduces the new notions of a bundle and bundle space in order to spread fibers uniformly across Tcl threads and available CPU cores.

It is currently a work in progress, with many planned features unimplemented.
