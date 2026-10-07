import Foundation

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
Task {
    exit(await Commands.run(arguments))
}
dispatchMain()
