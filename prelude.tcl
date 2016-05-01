
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
			while {1} {
				receive msg {
					puts stdout "\[$msg(sender)\] ($msg(type)): $msg(content)"
				}
			}
		}}
	}
}

package provide fiberbundle-prelude 1.0

