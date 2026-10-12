import Foundation
import Darwin

@main enum HeadroomCommand {
    static func main() {
        let output = HeadroomCLI.run(Array(CommandLine.arguments.dropFirst()))
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.exitCode)
    }
}
