import SwiftUI
import BackupHQCore

struct AddS3Sheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bucket = ""
    @State private var region = "eu-west-1"
    @State private var prefix = "photos"
    @State private var storageClass: S3StorageClass = .glacier
    @State private var profile = "default"
    @State private var useKeys = false
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var createBucket = true
    @State private var busy = false
    private let profiles = AWSCredentialsFile.listProfiles()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an S3 location").font(.title2).bold()
            Form {
                TextField("Name", text: $name, prompt: Text("Glacier archive"))
                TextField("Bucket", text: $bucket, prompt: Text("my-backup-archive"))
                TextField("Region", text: $region)
                TextField("Prefix (folder inside the bucket)", text: $prefix)
                Picker("Storage class", selection: $storageClass) {
                    ForEach(S3StorageClass.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text(storageHelp).font(.caption).foregroundStyle(.secondary)
                Toggle("Create the bucket if it does not exist", isOn: $createBucket)
                Divider()
                Toggle("Enter access keys instead of using a profile from ~/.aws", isOn: $useKeys)
                if useKeys {
                    TextField("Access key ID", text: $accessKey)
                    SecureField("Secret access key", text: $secretKey)
                    Text("Stored in your login Keychain.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("AWS profile", selection: $profile) {
                        ForEach(profiles.isEmpty ? ["default"] : profiles, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Connecting…" : "Add") {
                    busy = true
                    Task {
                        await model.addS3Location(name: name, bucket: bucket, region: region, prefix: prefix, storageClass: storageClass, profile: useKeys ? "" : profile,
                                                  accessKey: useKeys ? accessKey : "", secretKey: useKeys ? secretKey : "", createBucket: createBucket)
                        busy = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(bucket.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var storageHelp: String {
        switch storageClass {
        case .glacier: return "S3 Glacier Flexible Retrieval: cheap storage, restores take minutes to hours, 90-day minimum."
        case .deepArchive: return "Cheapest of all; restores take up to 12–48 hours, 180-day minimum. Good for a pure disaster copy."
        case .glacierIR: return "Glacier Instant Retrieval: instant access, a bit more per month, 90-day minimum."
        case .standardIA: return "Infrequent Access: instant, more per month, 30-day minimum."
        case .standard: return "Standard: instant and most expensive. Fine for testing."
        }
    }
}

struct EditLocationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var location: Location

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit location").font(.title2).bold()
            Form {
                TextField("Name", text: $location.name)
                if location.kind == .s3 {
                    TextField("Prefix", text: Binding(get: { location.s3Prefix ?? "" }, set: { location.s3Prefix = $0 }))
                    Picker("Storage class", selection: Binding(get: { S3StorageClass(rawValue: location.s3StorageClass ?? "") ?? .glacier }, set: { location.s3StorageClass = $0.rawValue })) {
                        ForEach(S3StorageClass.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Upload new content here automatically", isOn: $location.autoUpload)
                }
                Toggle("Enabled", isOn: $location.enabled)
                if location.kind == .local { Toggle("Primary library (where imports land)", isOn: $location.isPrimary) }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { Task { await model.update(location); dismiss() } }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 460)
    }
}
