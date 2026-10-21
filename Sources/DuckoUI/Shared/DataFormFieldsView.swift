import DuckoCore
import SwiftUI

/// An XMPP data form as one form section: its title as the header, then its instructions and the fields a user sees.
struct DataFormFieldsView: View {
    @Binding var form: DataFormInfo

    private var displayedFields: [RoomConfigField] {
        form.fields.filter(\.isDisplayed)
    }

    var body: some View {
        Section {
            ForEach(Array(form.instructions.enumerated()), id: \.offset) { _, instruction in
                Text(instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(displayedFields) { field in
                fieldRow(for: field)
                    .accessibilityIdentifier("data-form-field-\(field.variable ?? "")")
            }
        } header: {
            if let title = form.title {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(for field: RoomConfigField) -> some View {
        switch field.type {
        case "fixed":
            Text(field.values.joined(separator: "\n"))
                .foregroundStyle(.secondary)
        case "boolean":
            Toggle(isOn: boolBinding(for: field.id)) {
                fieldLabel(for: field, marksRequired: true)
            }
        case "list-single":
            Picker(selection: singleValueBinding(for: field.id)) {
                ForEach(field.options, id: \.value) { option in
                    Text(option.label ?? option.value).tag(option.value)
                }
            } label: {
                fieldLabel(for: field, marksRequired: true)
            }
        case "text-multi", "jid-multi":
            LabeledContent {
                TextEditor(text: multiLineBinding(for: field.id))
                    .frame(height: 60)
            } label: {
                fieldLabel(for: field, marksRequired: true)
            }
        case "list-multi":
            LabeledContent {
                VStack(alignment: .leading) {
                    ForEach(field.options, id: \.value) { option in
                        Toggle(
                            option.label ?? option.value,
                            isOn: multiSelectBinding(for: field.id, value: option.value)
                        )
                    }
                }
            } label: {
                fieldLabel(for: field, marksRequired: true)
            }
        case "text-private":
            SecureField(text: singleValueBinding(for: field.id), prompt: requiredPrompt(for: field)) {
                fieldLabel(for: field, marksRequired: false)
            }
        default:
            TextField(text: singleValueBinding(for: field.id), prompt: requiredPrompt(for: field)) {
                fieldLabel(for: field, marksRequired: false)
            }
        }
    }

    /// The field's label, with its description and, for controls without a placeholder, a required marker as subtitles.
    @ViewBuilder
    private func fieldLabel(for field: RoomConfigField, marksRequired: Bool) -> some View {
        Text(field.displayLabel)
        if let description = field.description {
            Text(description)
        }
        if marksRequired, field.isRequired {
            Text("Required")
        }
    }

    /// Text fields mark a required field with a "Required" placeholder, as macOS forms do.
    private func requiredPrompt(for field: RoomConfigField) -> Text? {
        field.isRequired ? Text("Required") : nil
    }

    // MARK: - Bindings

    private func boolBinding(for id: RoomConfigField.FieldID) -> Binding<Bool> {
        Binding(
            get: {
                let val = fieldValue(for: id)
                return val == "1" || val == "true"
            },
            set: { newValue in setFieldValue(for: id, value: newValue ? "1" : "0") }
        )
    }

    private func singleValueBinding(for id: RoomConfigField.FieldID) -> Binding<String> {
        Binding(
            get: { fieldValue(for: id) },
            set: { newValue in setFieldValue(for: id, value: newValue) }
        )
    }

    private func multiSelectBinding(for id: RoomConfigField.FieldID, value: String) -> Binding<Bool> {
        Binding(
            get: { form.fields.first(where: { $0.id == id })?.values.contains(value) ?? false },
            set: { isSelected in
                guard let index = form.fields.firstIndex(where: { $0.id == id }) else { return }
                form.fields[index].setOption(value, isSelected: isSelected)
            }
        )
    }

    private func multiLineBinding(for id: RoomConfigField.FieldID) -> Binding<String> {
        Binding(
            get: { form.fields.first(where: { $0.id == id })?.values.joined(separator: "\n") ?? "" },
            set: { newValue in
                if let index = form.fields.firstIndex(where: { $0.id == id }) {
                    form.fields[index].values = newValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                }
            }
        )
    }

    private func fieldValue(for id: RoomConfigField.FieldID) -> String {
        form.fields.first(where: { $0.id == id })?.values.first ?? ""
    }

    private func setFieldValue(for id: RoomConfigField.FieldID, value: String) {
        if let index = form.fields.firstIndex(where: { $0.id == id }) {
            form.fields[index].values = [value]
        }
    }
}
