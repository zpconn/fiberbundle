
package require Tcl 8.6
package require Thread 
package require TclOO
package require fiberbundle

namespace eval ::fiberbundle::prelude {
	#
	# logger - spawns a fiber named 'logger' which will log
	# messages sent to it to stdout.
	#
	proc logger {universe logfile {batch 0}} {
		$universe spawn_fiber logger {{out batch} {
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
	# agent - spawns an agent fiber, that is, a fiber whose sole
	# purpose is to store state.
	#
	proc agent {universe name initial_state} {
		$universe spawn_fiber $name {{start} {
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

					update_with_response {
						set update_lambda $msg(content)
						set state [apply $update_lambda $state]
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
					send logger error "agent_get received a response other than get_response!"
				}
			}
		}
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
		}
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
		}
	}
}

package provide fiberbundle-prelude 1.0

