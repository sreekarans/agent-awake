import Darwin
import Foundation

private func main() {
    let arguments = CommandLine.arguments
    let command = arguments.count >= 2 ? arguments[1] : nil
    do {
        let controller = try Controller()
        guard arguments.count >= 2 else {
            throw ControllerError.invalidArguments
        }

        switch arguments[1] {
        case "hook":
            guard arguments.count == 4 else {
                throw ControllerError.invalidArguments
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            controller.handleHook(
                source: arguments[2],
                action: arguments[3],
                input: input
            )
        case "reconcile":
            controller.reconcileNow()
        case "status":
            controller.printStatus()
        case "history":
            try controller.printHistory(arguments: Array(arguments.dropFirst(2)))
        case "__self-test-large-process-output":
            controller.selfTestLargeProcessOutput()
        default:
            throw ControllerError.invalidArguments
        }
    } catch {
        if command == "hook" {
            // Hook failures must fail open and must not emit protocol-breaking output.
            exit(0)
        }
        let message = "agent-awake: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(2)
    }
}

main()
