import Foundation

extension HarnessConfig {
    /// A default Swift property value is not a Codable decoding default. `$schema`
    /// is optional metadata, including in our shipped descriptors, so decoding
    /// must not reject an otherwise valid authoring document when it is absent.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(String.self, forKey: .schema) ?? "../harness.schema.json"
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        source = try values.decode(Source.self, forKey: .source)
        match = try values.decodeIfPresent([String].self, forKey: .match)
        processNames = try values.decodeIfPresent([String].self, forKey: .processNames)
        process = try values.decodeIfPresent(ProcessRule.self, forKey: .process)
        map = try values.decodeIfPresent(Mapping.self, forKey: .map)
        detached = try values.decodeIfPresent(Bool.self, forKey: .detached)
        multiSession = try values.decodeIfPresent(Bool.self, forKey: .multiSession)
        selection = try values.decodeIfPresent(Selection.self, forKey: .selection)
        quota = try values.decodeIfPresent(Quota.self, forKey: .quota)
        capabilities = try values.decodeIfPresent([String: CapabilityRule].self, forKey: .capabilities)
        idleAfter = try values.decodeIfPresent(Double.self, forKey: .idleAfter)
        staleAfter = try values.decodeIfPresent(Double.self, forKey: .staleAfter)
        fallbackName = try values.decodeIfPresent(String.self, forKey: .fallbackName)
        mark = try values.decodeIfPresent(String.self, forKey: .mark)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
        presentation = try values.decodeIfPresent(Presentation.self, forKey: .presentation)
        compatibility = try values.decodeIfPresent(Compatibility.self, forKey: .compatibility)
    }
}
