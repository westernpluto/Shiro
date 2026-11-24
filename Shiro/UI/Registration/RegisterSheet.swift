import SwiftUI

/// Registers this iPhone with a console, either automatically through PSN
/// (no PIN) or with the 8-digit pairing PIN shown on the console.
struct RegisterSheet: View {
    let entry: ConsoleEntry
    @EnvironmentObject private var psn: PSNAuth
    @EnvironmentObject private var store: ConsoleStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var manualAccountId = ""
    @State private var working = false
    @State private var error: String?
    @State private var showLogin = false
    @State private var registration: PinRegistration?

    private var canAutoRegister: Bool {
        psn.isSignedIn && (entry.psn?.remotePlayEnabled == true || (entry.psn == nil && !entry.isPS5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Console", value: entry.name)
                    LabeledContent("Model", value: entry.modelName)
                    if let a = entry.discovered?.address { LabeledContent("Address", value: a) }
                }

                Section {
                    if psn.isSignedIn {
                        Button {
                            dismiss()
                            model.autoRegister(entry)
                        } label: {
                            Label("Register automatically", systemImage: "bolt.fill")
                        }
                        .disabled(!canAutoRegister)
                    } else {
                        Button { showLogin = true } label: {
                            Label("Sign in to PSN to register without a PIN", systemImage: "person.crop.circle")
                        }
                    }
                } header: {
                    Text("Automatic (no PIN)")
                } footer: {
                    if psn.isSignedIn && !canAutoRegister {
                        Text("This console isn't linked to your PSN account. Turn on Remote Play on the console while signed in with the same account, then pull to refresh.")
                    } else {
                        Text("Uses your PlayStation Network account to pair — just like the official app. The console must have Remote Play enabled and be signed in to the same account.")
                    }
                }

                Section {
                    TextField("8-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                    if !psn.isSignedIn {
                        TextField("PSN Account ID (Base64)", text: $manualAccountId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        Task { await registerWithPin() }
                    } label: {
                        if working { ProgressView() } else { Label("Register with PIN", systemImage: "number") }
                    }
                    .disabled(working || pin.filter(\.isNumber).count != 8 || entry.discovered == nil)
                } header: {
                    Text("With PIN")
                } footer: {
                    if entry.discovered == nil {
                        Text("PIN registration only works when your iPhone and the console are on the same Wi-Fi. Use automatic registration above to set up from anywhere.")
                    } else {
                        Text("On the console open Settings › System › Remote Play › Link Device (PS5) or Settings › Remote Play Connection Settings › Add Device (PS4).")
                    }
                }

                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Register")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        registration?.cancel()
                        dismiss()
                    } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
            .sheet(isPresented: $showLogin) { PSNLoginView() }
        }
    }

    private func registerWithPin() async {
        guard let d = entry.discovered, let pinValue = UInt32(pin.filter(\.isNumber)) else { return }
        let accountId: Data
        if let creds = psn.credentials {
            accountId = creds.accountId
        } else if let manual = Data(base64Encoded: manualAccountId.trimmingCharacters(in: .whitespaces)), manual.count == 8 {
            accountId = manual
        } else {
            error = RegistrationError.needsPSN.localizedDescription
            return
        }
        working = true
        error = nil
        let r = PinRegistration()
        registration = r
        do {
            let host = try await r.register(address: d.address, target: d.target, accountId: accountId, pin: pinValue)
            store.addRegistered(host, address: d.address, psnDuid: entry.psn?.duid)
            working = false
            dismiss()
        } catch {
            working = false
            self.error = error.localizedDescription
        }
    }
}
