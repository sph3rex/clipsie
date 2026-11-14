import Foundation

func L(_ english: String, _ arguments: String...) -> String {
    let format = Bundle.main.localizedString(forKey: english, value: english, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments.map { $0 as NSString as CVarArg })
}
