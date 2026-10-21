import DuckoCore
import Foundation

/// Prompts for every field of a data form the user can edit, printing its fixed text on the way.
/// Pressing Enter keeps a field's current values.
func promptForDataFormValues(_ fields: inout [RoomConfigField], formatter: any CLIFormatter) throws {
    for index in fields.indices where fields[index].isDisplayed {
        if fields[index].isFixed {
            fields[index].values.forEach { print($0) }
        } else {
            try promptForValues(of: &fields[index], formatter: formatter)
        }
    }
}

/// The values typed for a data form field, or nil when nothing was typed, which keeps its current values.
/// `lines` holds one line for a single-line field and every line typed for a text-multi or jid-multi field.
/// A hidden value is taken as typed, spaces included.
func dataFormValues(typed lines: [String], for field: RoomConfigField) throws -> [String]? {
    if field.type == "text-private" {
        return lines.first.flatMap { $0.isEmpty ? nil : [$0] }
    }
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = trimmed.first(where: { !$0.isEmpty }) else { return nil }
    switch field.type {
    case "boolean":
        return try [booleanValue(first)]
    case "text-multi":
        return lines
    case "jid-multi":
        return trimmed
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    case "list-single":
        return try [optionValue(first, in: field)]
    case "list-multi":
        let chosen = try first.split(separator: ",").map {
            try optionValue($0.trimmingCharacters(in: .whitespaces), in: field)
        }
        return field.optionValues(Set(chosen))
    default:
        return [first]
    }
}

private func promptForValues(of field: inout RoomConfigField, formatter: any CLIFormatter) throws {
    if let description = field.description { print(description) }
    if !field.options.isEmpty {
        let options = field.options.map { option in
            option.label.map { $0 == option.value ? option.value : "\(option.value) (\($0))" } ?? option.value
        }
        print("Options: \(options.joined(separator: ", "))")
    }
    while true {
        guard let lines = try readValues(for: field) else {
            if field.isMissingRequiredValue { throw CLIError.inputEnded(field: field.displayLabel) }
            return
        }
        do {
            if let values = try dataFormValues(typed: lines, for: field) {
                field.values = values
            }
        } catch {
            print(formatter.formatError(error))
            continue
        }
        guard field.isMissingRequiredValue else { return }
        print("\(field.displayLabel) is required.")
    }
}

/// Reads what the user types for one field: a hidden line for text-private, lines up to an empty one for the
/// multi-line types, else one line. Returns nil when input ends before anything is typed, or for a hidden line when
/// there is no terminal. A hidden field that still needs a required value throws instead.
private func readValues(for field: RoomConfigField) throws -> [String]? {
    let marker = field.isRequired ? " (required)" : ""
    if field.type == "text-private" {
        guard let secret = try CredentialHelper.readHiddenLine(prompt: "\(field.displayLabel)\(marker): ") else {
            if field.isMissingRequiredValue { throw CLIError.noHiddenInput(field: field.displayLabel) }
            return nil
        }
        return [secret]
    }
    let current = dataFormValueText(field)
    switch field.type {
    case "text-multi", "jid-multi":
        print("\(field.displayLabel)\(marker) [\(current)], one per line, empty line to finish:")
        var lines: [String] = []
        while let line = readLine() {
            if line.isEmpty { return lines }
            lines.append(line)
        }
        return lines.isEmpty ? nil : lines
    default:
        print("\(field.displayLabel)\(marker) [\(current)]: ", terminator: "")
        return readLine().map { [$0] }
    }
}

/// The XEP-0004 boolean for a typed answer: 1 for yes, 0 for no.
private func booleanValue(_ typed: String) throws -> String {
    switch typed.lowercased() {
    case "1", "true", "yes", "y", "on": "1"
    case "0", "false", "no", "n", "off": "0"
    default: throw CLIError.notYesOrNo(typed)
    }
}

private func optionValue(_ typed: String, in field: RoomConfigField) throws -> String {
    guard let option = field.options.first(where: { $0.value == typed || $0.label == typed }) else {
        throw CLIError.unlistedOption(typed)
    }
    return option.value
}
