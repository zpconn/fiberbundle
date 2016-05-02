
package require Tcl 8.6
package require Thread 
package require TclOO
package require fiberbundle

namespace eval ::fiberbundle::prelude {
	#
	# logger - spawns a fiber named 'logger' which will log
	# messages sent to it to stdout.
	#
	proc logger {bundle_space} {
		$bundle_space spawn_fiber logger {{} {
			loop {
				receive msg {
					puts stdout "\[$msg(sender)\] ($msg(type)): $msg(content)"
				}
			}
		}}
	}

	#
	# agent - spawns an agent fiber, that is, a fiber whose sole
	# purpose is to store state.
	#
	proc agent {bundle_space name initial_state} {
		$bundle_space spawn_fiber $name {{start} {
			set state $start

			loop {
				receive msg {
					switch $msg(type) {
						get {
							# It's unclear how to implement this currently.
							# We can't just "return" the state back to the sender
							# of the message.

							# As a placeholder, for now we simply log the value of
							# the state.

							send logger info $state
						}

						put {
							set state $msg(content)
						}

						update {
							set update_lambda $msg(content)
							set state [apply $update_lambda $state]
						}

						default {}
					}
				}
			}
		}} $initial_state
	}
}

package provide fiberbundle-prelude 1.0

