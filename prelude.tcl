
package require Tcl 8.6
package require Thread 
package require TclOO
package require fiberbundle

#
# The fiberbundle prelude is a small standard library of utilies that will be useful
# to mostly all applications built using fiberbundle but are nevertheless not
# central to the library's implementation.
#
# Note that mostly all the functions here are designed to be invoked from within
# a fiber.
#

namespace eval ::fiberbundle::prelude {
	#
	# spawn_logger - spawns a fiber named 'logger' which will log
	# messages sent to it to stdout.
	#
	proc spawn_logger {logfile {batch 0}} {
		spawn_fiber logger {{out batch} {
			set log [open $out a]
			set counter 0

			receive_forever msg {
				incr counter
				puts $log "\[$msg(sender)\] ($msg(type)): $msg(content)"

				if {!$batch} {
					flush $log
				} elseif {$counter % 1000 == 0} {
					set counter 0
					flush $log
				}
			}
		}} $logfile $batch
	}

	#
	# spawn_simple_agent - spawns an agent fiber, that is, a fiber whose sole
	# purpose is to store state. This differs from spawn_agent in that it
	# provides a simple but ready-to-go implementation of the basic agent
	# commands (get/put/update).
	#
	proc spawn_simple_agent {name initial_state} {
		spawn_fiber $name {{start} {
			set state $start

			receive_forever msg {
				switch $msg(type) {
					get {
						# We send a message back to the sender of this
						# message with the value of the current state.

						send $msg(sender) get_response $state
					}

					log {
						send logger info "Current state = '$state'"
					}

					put {
						set state $msg(content)
					}

					put_with_response {
						set state $msg(content)
						send $msg(sender) put_response success
					}

					update {
						set update_lambda $msg(content)
						set state [apply $update_lambda $state]
					}

					update_closure {
						set update_closure $msg(content)
						set state [apply {*}$update_closure $state]
					}

					update_with_response {
						set update_lambda $msg(content)
						set state [apply $update_lambda $state]
						send $msg(sender) update_response success
					}

					update_closure_with_response {
						set update_closure $msg(content)
						set state [apply {*}$update_closure $state]
						send $msg(sender) update_response success
					}

					default {}
				}
			}
		}} $initial_state
	}

	#
	# agent_get - given the name of an agent, this synchronsouly grabs the
	# state contained in the agent fiber.
	#
	# Note that this can only be invoked from within a fiber.
	#
	proc agent_get {name} {
		send $name get {}

		receive_once msg {
			switch $msg(type) {
				get_response {
					return $msg(content)
				}
				
				default {
					send logger error "agent_get received a response other than get_response ([array get msg])!"
				}
			}
		} [dict create sender_whitelist [list $name] type_whitelist [list get_response]]
	}

	#
	# agent_put - given the name of an agent and a new state value, this sends
	# a put command to the agent and blocks until it receives a response from the
	# agent indicating success.
	#
	# This must be invoked from within a fiber.
	# 
	proc agent_put {name value} {
		send $name put_with_response $value

		receive_once msg {
			switch $msg(type) {
				put_response {
					if {$msg(content) == "success"} {
						return 1
					} else {
						return 0
					}
				}

				default {
					send logger error "agent_put received a response other than put_response! Agent: $name. New value: $value"
					return 0
				}
			}
		} [dict create sender_whitelist [list $name] type_whitelist [list put_response]]
	}

	#
	# async_agent_put - asynchronously sends a `put` message to the specified agent.
	#
	# Does not wait for a response of any kind and does not instruct the agent
	# to send a response. 
	#
	# Returns immediately.
	#
	proc async_agent_put {name value} {
		send $name put $value
	}

	#
	# agent_update - given the name of an agent and an update lambda expression, this sends
	# an update command to the agent and blocks until it receives a response indicating
	# success.
	#
	# This must be invoked from within a fiber.
	#
	proc agent_update {name lambda} {
		send $name update_with_response $lambda

		receive_once msg {
			switch $msg(type) {
				update_response {
					if {$msg(content) == "success"} {
						return 1
					} else {
						return 0
					}
				}

				default {
					send logger error "agent_update received a response other than put_response! Agent: $name. Lambda: $lambda"
					return 0
				}
			}
		} [dict create sender_whitelist [list $name] type_whitelist [list update_response]]
	}

	#
	# async_agent_update - asynchronously sends an `update` message to the specified agent.
	#
	# Does not wait for a response of any kind and does not instruct the agent to
	# send a response.
	#
	# Returns immediately.
	#
	proc async_agent_update {name lambda} {
		send $name update $lambda
	}

	#
	# async_agent_update_closure - asynchronously sends an `update_closure` message to the specified agent.
	#
	# Does not wait for a response of any kind and does not instruct the agent
	# to send a response.
	#
	# Returns immediately.
	#
	proc async_agent_update_closure {name closure} {
		send $name update_closure $closure
	}

	#
	# agent -- defines a generic interface that any agent must implement.
	#
	# The implementations provided here are placeholders. If you don't intend on modifying them,
	# you're better off just using the simple agent interface above, which saves you the trouble
	# of needing to deal with classes.
	#
	oo::class create agent {
		constructor {} {
			variable state
			set state {}
		}

		method get {} {
			variable state
			return $state
		}

		method put {x} {
			variable state
			set state $x
		}

		method update {lambda} {
			variable state
			set state [apply $lambda $state]
		}
	}

	#
	# spawn_agent - spawns a fiber with an object whose type is a subclass
	# of the generic agent class. Message handlers are created in the fiber
	# which correspond to the overloaded methods of the class.
	#
	# The resulting agent is compatible with the agent_put/agent_get interface.
	#
	proc spawn_agent {name agent_subclass}  {
		spawn_fiber $name {{} {
			# Create the agent object.
			set agent_obj [$agent_subclass new]

			# Initiate the message loop and setup event handlers which act as
			# proxies for the agent class methods.
			receive_forever msg {
				switch $msg(type) {
					get {
						set state [$agent_obj get]
						send $msg(sender) get_response $state
					}

					log {
						send logger info "Current state = '[$agent_obj get]'"
					}

					put {
						$agent_obj put $msg(content)
					}

					put_with_response {
						$agent_obj put $msg(content)
						send $msg(sender) put_response success
					}

					update {
						$agent_obj update $msg(content)
					}

					update_with_response {
						$agent_obj update $msg(content)
						send $msg(sender) update_response success
					}

					default {}
				}
			}
		}}
	}

	#
	# map - maps a lambda expression over a list of inputs, with the lambdas being
	# evaluated in parallel in separate fibers. Note that each lambda expression can
	# still communicate with other fibers (like agents offering shared state) and
	# thus quite complex behavior can be produced here.
	#
	# This implementation is synchronous, meaning it waits for all computations
	# to complete before returning. It returns a list of outputs, one output
	# for each input.
	#
	proc map {inputs lambda} {
		set fiber_name [current_fiber]

		# Spawn the workers.
		set idx 0
		set worker_fibers [list]
		foreach input $inputs {
			set worker_name map_worker_[new_pid]
			lappend worker_fibers $worker_name
			spawn_fiber $worker_name {{lambda input target_fiber idx} {
				set result [apply $lambda $input]
				send $target_fiber worker_result $result $idx
			}} $lambda $input $fiber_name $idx

			incr idx
		}

		# Accumulate all the results from the workers. Note that they
		# may come back to us in any order.
		set output [dict create]
		while {[dict size $output] < [llength $inputs]} {
			receive_once msg {
				switch $msg(type) {
					worker_result {
						lassign $msg(content) result idx
						dict set output $idx $result
					}

					default {}
				}
			} [dict create sender_whitelist $worker_fibers]
		}

		# Put the outputs in the desired order and return them.
		set outputs [list]
		for {set i 0} {$i < [llength $inputs]} {incr i} {
			lappend outputs [dict get $output $i]
		}

		return $outputs
	}

	#
	# closure - creates a lambda expression which is able to reference variables 
	# contained in its enclosing lexical scope as if it were a closure.
	#
	# Note that this can be very inefficient if the enclosing scope is large, as
	# it makes copies of all the variables.
	#
	# The lambda expression can be evaluated via `apply`.
	#
	proc closure {arguments body} {
		set vars [lmap v [uplevel 1 info vars] {
			if {[uplevel 1 [list info exist $v]] && \
				![uplevel 1 [list array exists $v]]} {
				set v
			} else {
				continue
			}
		}]

		return [list \
					[list [list {*}$vars {*}$arguments] $body] \
					{*}[lmap v $vars {uplevel 1 [list set $v]}]]
	}

	#
	# fast_closure - this version of `closure` can often be considerably faster
	# because it will only create copies of the variables specified in the
	# `refs` list.
	#
	proc fast_closure {refs arguments body} {
		return [list \
					[list [list {*}$refs {*}$arguments] $body] \
					{*}[lmap v $refs {uplevel 1 [list set $v]}]]
	}
}

package provide fiberbundle-prelude 1.0

