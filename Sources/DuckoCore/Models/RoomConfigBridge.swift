import DuckoXMPP

public extension DataFormInfo {
    init(from form: DataForm) {
        self.init(
            title: form.title,
            instructions: form.instructions,
            fields: form.fields.enumerated().map { RoomConfigField(from: $1, position: $0) }
        )
    }
}

public extension RoomConfigField {
    init(from field: DataFormField, position: Int) {
        self.init(
            variable: field.variable,
            position: position,
            type: field.type,
            label: field.label,
            description: field.description,
            isRequired: field.isRequired,
            values: field.values,
            options: field.options.map { (label: $0.label, value: $0.value) }
        )
    }

    /// Converts back to a ``DataFormField`` for submission, leaving out the blank lines of a jid-multi field.
    func toDataFormField() -> DataFormField {
        DataFormField(
            variable: variable,
            type: type,
            label: label,
            description: description,
            isRequired: isRequired,
            values: type == "jid-multi" ? values.filter { !$0.isBlank } : values,
            options: options.map { (label: $0.label, value: $0.value) }
        )
    }
}
