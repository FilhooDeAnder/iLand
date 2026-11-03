import SwiftUI
import AppKit

/// Abas de Ajustes que cada pessoa configura do seu jeito. As mesmas views aparecem no assistente de configuração.

struct ProfileSettings: View {
    @AppStorage(Prefs.Key.userName) private var name = ""
    @AppStorage(Prefs.Key.userRole) private var role = ""
    @AppStorage(Prefs.Key.editor) private var editor = ""
    @AppStorage(Prefs.Key.terminal) private var terminal = "com.apple.Terminal"
    @AppStorage(Prefs.Key.assistantFrom) private var from = 7
    @AppStorage(Prefs.Key.assistantTo) private var to = 19

    var body: some View {
        SettingsPage(symbol: "person.crop.circle.fill", title: "Você", subtitle: "Como o assistente te chama e com quais apps você trabalha.") {
            GlassSection("Perfil", footer: "Entra no prompt do assistente. Fica só neste Mac.") {
                SettingRow("Nome") { GlassField(placeholder: "como o assistente te chama", text: $name) }
                SettingRow("O que você faz", divider: false) { GlassField(placeholder: "ex.: dev backend, suporte, comercial", text: $role) }
            }
            GlassSection("Apps") {
                SettingRow("Editor de código", detail: "Onde o assistente abre um projeto.") {
                    Picker("", selection: $editor) {
                        Text("Automático (\(Editor.installed.first?.name ?? "Finder"))").tag("")
                        ForEach(Editor.installed, id: \.bundle) { Text($0.name).tag($0.bundle) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                SettingRow("Terminal", detail: "Onde abre o SSH das máquinas.", divider: false) {
                    Picker("", selection: $terminal) { ForEach(Terminal.installed, id: \.bundle) { Text($0.name).tag($0.bundle) } }
                        .labelsHidden().frame(width: 220)
                }
            }
            GlassSection("Expediente do assistente", footer: "Fora do expediente o iLand não registra atividade nem manda avisos. A conversa continua respondendo.") {
                SettingRow("Começa às \(from)h") { Stepper("", value: $from, in: 0...23).labelsHidden() }
                SettingRow("Termina às \(to)h", divider: false) { Stepper("", value: $to, in: 0...23).labelsHidden() }
            }
        }
    }
}

/// Provedores conectados e o modelo de cada papel.
struct ModelsSettings: View {
    @AppStorage(Prefs.Key.usageFromAPI) private var usageFromAPI = true
    @State private var status: [Provider: (String, StatusPill.Kind)] = [:]
    @State private var ollamaModels: [String] = []

    var body: some View {
        SettingsPage(symbol: "sparkles", title: "Modelos", subtitle: "Conecte o que você usa e escolha quem faz cada tarefa.") {
            HStack(spacing: Theme.gap) {
                ForEach(Provider.allCases) { p in
                    VStack(alignment: .leading, spacing: 12) {
                        GlassIcon(symbol: p.symbol, size: 38)
                        Text(p.title).font(.system(size: 16, weight: .bold, design: .rounded))
                        StatusPill(text: status[p]?.0 ?? "verificando…", kind: status[p]?.1 ?? .idle)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface()
                }
            }
            .glassGroup(spacing: Theme.gap)
            HStack {
                Text("O iLand usa o login de cada ferramenta e não guarda chave de API.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Verificar de novo") { refresh() }.glassButton()
            }
            GlassSection("Quem faz cada tarefa", footer: "Só o Assistente usa ferramentas (dia, projetos, ClickUp). Claude Code, Codex e modelos cloud do Ollama funcionam bem nele.") {
                ForEach(Array(Role.allCases.enumerated()), id: \.element) { i, r in RoleRow(role: r, ollamaModels: ollamaModels, divider: i < Role.allCases.count - 1) }
            }
            GlassSection("Uso do Claude nas orelhas") {
                SettingRow("Consultar o uso pela conta do Claude Code", detail: "Lê o login do Claude Code no Keychain (pelo comando `security`) e pergunta à Anthropic.", divider: false) {
                    Toggle("", isOn: $usageFromAPI).labelsHidden()
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = [:]
        CLI.reset()
        DispatchQueue.global(qos: .userInitiated).async {
            let claude: (String, StatusPill.Kind) = CLI.locate("claude") != nil ? ("instalado", .ok) : ("não encontrado", .warn)
            var codex: (String, StatusPill.Kind) = ("não encontrado", .warn)
            if let exe = CLI.locate("codex") {
                let r = CLI.run(exe, ["login", "status"], timeout: 10)
                codex = r.status == 0 ? ("conectado", .ok) : ("sem login", .warn)
            }
            DispatchQueue.main.async { status[.claude] = claude; status[.codex] = codex }
        }
        Task {
            let m = await Ollama.models()
            await MainActor.run {
                ollamaModels = m ?? []
                status[.ollama] = m.map { $0.isEmpty ? ("sem modelos", .warn) : ("\($0.count) modelo\($0.count == 1 ? "" : "s")", .ok) } ?? ("fechado", .warn)
            }
        }
    }
}

struct RoleRow: View {
    let role: Role
    let ollamaModels: [String]
    var divider = true
    @State private var provider: Provider = .claude
    @State private var model = ""

    var body: some View {
        SettingRow(role.title, divider: divider) {
            HStack(spacing: 8) {
                Picker("", selection: $provider) { ForEach(Provider.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 140)
                    .onChange(of: provider) { p in
                        let options = suggestions(p)
                        if !options.contains(model) { model = options.first ?? "" }
                        save()
                    }
                let options = suggestions(provider)
                if options.isEmpty {
                    GlassField(placeholder: "modelo", text: $model, width: 150).onSubmit(save)
                } else {
                    Picker("", selection: $model) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                        if !options.contains(model), !model.isEmpty { Text(model).tag(model) }
                    }
                    .labelsHidden().frame(width: 150).onChange(of: model) { _ in save() }
                }
            }
        }
        .onAppear { let c = role.choice; provider = c.provider; model = c.model }
    }

    private func suggestions(_ p: Provider) -> [String] { p == .ollama ? ollamaModels : p.suggested }
    private func save() { if LLM.safeModel(model) { role.set(provider, model) } }
}

struct ProjectsSettings: View {
    @AppStorage(Prefs.Key.projectRoots) private var rootsText = ""
    @State private var learned: [String] = []
    @State private var searching = false

    var body: some View {
        let roots = rootsText.split(separator: "\n").map(String.init)
        SettingsPage(symbol: "folder.fill", title: "Projetos", subtitle: "Um projeto é uma pasta com git. O iLand aprende pelos arquivos que você abre e pelas pastas onde você usa o Claude Code ou o Codex.") {
            GlassSection("Pastas de projetos", footer: "Se você guarda os projetos numa pasta, adicione aqui: as subpastas dela também contam.") {
                ForEach(roots, id: \.self) { r in
                    SettingRow((r as NSString).lastPathComponent, detail: (r as NSString).abbreviatingWithTildeInPath) {
                        Button("Remover") { rootsText = roots.filter { $0 != r }.joined(separator: "\n") }.glassButton()
                    }
                }
                SettingRow(roots.isEmpty ? "Nenhuma pasta adicionada" : "Outra pasta", divider: false) {
                    Button("Adicionar pasta…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let u = panel.url, !roots.contains(u.path) { rootsText = (roots + [u.path]).joined(separator: "\n") }
                    }
                    .glassButton(prominent: roots.isEmpty)
                }
            }
            GlassSection("Aprendidos · \(learned.count)") {
                SettingRow("Procurar nas sessões do Claude Code e do Codex", detail: "Últimos 30 dias.", divider: !learned.isEmpty) {
                    Button(searching ? "Procurando…" : "Procurar agora") {
                        searching = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            ProjectRoots.bootstrap()
                            let k = ProjectRoots.known
                            DispatchQueue.main.async { learned = k; searching = false }
                        }
                    }
                    .glassButton().disabled(searching)
                }
                let shown = Array(learned.suffix(12).reversed())
                ForEach(Array(shown.enumerated()), id: \.element) { i, p in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(Theme.textSecondary).frame(width: 18)
                        Text((p as NSString).lastPathComponent).font(Theme.label)
                        Text((p as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { if i < shown.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) } }
                }
            }
        }
        .onAppear { learned = ProjectRoots.known }
    }
}

/// Máquinas Linux por SSH. Opcional: sem máquinas, a página some do notch.
struct MachinesSettings: View {
    var monitor: MachinesMonitor?
    @AppStorage(Prefs.Key.machines) private var csv = ""
    @State private var newHost = ""
    @State private var test = ""
    @State private var testOK = false
    @State private var testing = false

    var body: some View {
        let list = Prefs.machines
        SettingsPage(symbol: "server.rack", title: "Máquinas", subtitle: "Servidores Linux que você acompanha por SSH. Sem máquinas, a página some do notch.") {
            GlassSection("Acompanhando · \(list.count)") {
                if list.isEmpty { SettingRow("Nenhuma máquina", detail: "A página Máquinas fica escondida.", divider: false) { EmptyView() } }
                ForEach(Array(list.enumerated()), id: \.element) { i, h in
                    SettingRow(h, divider: i < list.count - 1) { Button("Remover") { save(list.filter { $0 != h }) }.glassButton() }
                }
            }
            GlassSection("Adicionar", footer: "O iLand só lê CPU, memória e disco por SSH, sem senha (chave ou agente). Nada é instalado no servidor.") {
                let hosts = SSHConfig.hosts().filter { !list.contains($0) }
                if !hosts.isEmpty {
                    SettingRow("Do meu ~/.ssh/config") {
                        Menu("Escolher host") { ForEach(hosts, id: \.self) { h in Button(h) { newHost = h } } }.frame(width: 200)
                    }
                }
                SettingRow("Host", detail: "Apelido do ssh ou usuario@endereco.") { GlassField(placeholder: "ex.: web-1", text: $newHost, width: 220) }
                SettingRow(test.isEmpty ? "Conexão" : (testOK ? "Conectou" : "Não conectou"), detail: test.isEmpty ? nil : test, divider: false) {
                    HStack(spacing: 8) {
                        Button(testing ? "Testando…" : "Testar") { probe() }.glassButton().disabled(testing || !Prefs.isValidHost(newHost))
                        Button("Adicionar") { save(list + [newHost]); newHost = ""; test = "" }.glassButton(prominent: true).disabled(!Prefs.isValidHost(newHost))
                    }
                }
            }
        }
    }

    private func save(_ hosts: [String]) {
        csv = hosts.filter(Prefs.isValidHost).joined(separator: ",")
        monitor?.reload()
    }

    private func probe() {
        let h = newHost
        testing = true; test = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MachinesMonitor.probe(h)
            DispatchQueue.main.async {
                testing = false
                testOK = s != nil
                test = s.map { "CPU \($0.cpuPct)% · RAM \($0.ramPct)% · disco \($0.diskPct)%" } ?? "Confira o ssh no terminal (até 90 s de espera)."
            }
        }
    }
}

/// Hosts do ~/.ssh/config (sem curingas). Só leitura.
enum SSHConfig {
    static func hosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let f = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 2, f[0].lowercased() == "host" else { continue }
            for h in f.dropFirst().map(String.init) where !h.contains("*") && !h.contains("?") && Prefs.isValidHost(h) && !out.contains(h) { out.append(h) }
        }
        return out
    }
}

struct ClickUpSettings: View {
    @State private var token = ""
    @State private var state = ""
    @State private var connected = false
    @State private var busy = false

    var body: some View {
        SettingsPage(symbol: "checklist", title: "ClickUp", subtitle: "Suas tasks e o timer, para o assistente saber no que você está.") {
            HStack(spacing: 14) {
                StatusPill(text: busy ? "verificando…" : (state.isEmpty ? "não conectado" : state), kind: connected ? .ok : (state.isEmpty ? .idle : .warn))
                Spacer()
                Link("Onde gerar o token ↗", destination: URL(string: "https://app.clickup.com/settings/apps")!).font(Theme.caption).foregroundStyle(Theme.accent)
            }
            GlassSection("Token pessoal", footer: "O token fica no Keychain deste Mac. Ele só lê suas tasks e o timer, e para o timer quando você aprova.") {
                SettingRow("Token", detail: "Começa com pk_.") { GlassField(placeholder: "pk_…", text: $token, secure: true, width: 260) }
                SettingRow(connected ? "Trocar a conta" : "Conectar", divider: false) {
                    HStack(spacing: 8) {
                        if connected { Button("Desconectar") { disconnect() }.glassButton().disabled(busy) }
                        Button("Salvar e testar") { save() }.glassButton(prominent: true).disabled(busy || token.isEmpty)
                    }
                }
            }
        }
        .onAppear(perform: check)
    }

    private func disconnect() {
        busy = true
        DispatchQueue.global().async { _ = ClickUp.saveToken(""); DispatchQueue.main.async { busy = false; connected = false; state = "" } }
    }

    private func save() {
        busy = true
        let t = token
        DispatchQueue.global(qos: .userInitiated).async {
            guard ClickUp.saveToken(t) else { DispatchQueue.main.async { busy = false; state = "Não consegui salvar no Keychain." }; return }
            DispatchQueue.main.async { token = "" }
            verify()
        }
    }

    private func check() { busy = true; DispatchQueue.global(qos: .userInitiated).async { verify(quietIfMissing: true) } }

    /// Fora da main: ler o Keychain pode abrir o pedido de permissão.
    private func verify(quietIfMissing: Bool = false) {
        Task.detached {
            var ok = false
            let msg: String
            do { msg = "conectado como \(try await ClickUp.whoAmI())"; ok = true }
            catch ClickUp.Failure.noToken { msg = quietIfMissing ? "" : "sem token" }
            catch ClickUp.Failure.unauthorized { msg = "token recusado" }
            catch { msg = "sem resposta do ClickUp" }
            let isOK = ok
            await MainActor.run { busy = false; state = msg; connected = isOK }
        }
    }
}

/// O que o iLand lê e o que sai do Mac. Aparece na configuração inicial e em Ajustes › Privacidade.
struct PrivacySettings: View {
    @AppStorage(Prefs.Key.readSessions) private var readSessions = true

    var body: some View {
        SettingsPage(symbol: "hand.raised.fill", title: "Privacidade", subtitle: "Tudo o que o iLand lê, onde fica e o que sai deste Mac.") {
            GlassSection("O que o iLand lê (fica neste Mac)") {
                item("macwindow", "Apps e janelas", "O app em uso, o título da janela e o arquivo aberto, pela Acessibilidade. Janela anônima, campo de senha e tela bloqueada não têm o título salvo. Fica 30 dias. O botão Pausar da página Hoje para o registro.")
                SettingRow("Sessões do Claude Code e do Codex", detail: "A pasta, o horário e o último pedido de cada sessão, com senhas mascaradas. Serve para o \"onde parei\", o resumo do dia e o assistente. As conversas do app do Claude não ficam no Mac, então o iLand não vê nada delas.", symbol: "terminal") {
                    Toggle("", isOn: $readSessions).labelsHidden()
                }
                item("arrow.triangle.branch", "Projetos com git", "Os arquivos alterados, os commits do dia e a seção \"Em progresso\" do docs/ESTADO.md, se existir.")
                item("doc.on.clipboard", "Área de transferência", "As últimas 50 coisas que você copia. Senhas de gerenciadores não entram.")
                item("cpu", "Processos e sensores", "CPU, memória, disco, bateria e temperatura.")
                item("key.fill", "Contas", "O login do Claude Code (só para ler o uso) e o token do ClickUp. Ficam no Keychain.", divider: false)
            }
            GlassSection("O que sai do Mac", footer: "Nenhum dado vai para um servidor da Loop.") {
                item("sparkles", "Para o modelo que você escolher", "A sua pergunta, o contexto do dia e o que as ferramentas leem (títulos de janela, projetos, tasks). Vai para a Anthropic, a OpenAI ou o Ollama cloud, conforme a sua escolha em Modelos. Com um modelo local do Ollama, nada sai.")
                item("checklist", "Para o ClickUp", "A leitura das suas tasks e do timer. O iLand só para o timer quando você aprova.")
                item("server.rack", "Para as suas máquinas", "Um SSH de leitura a cada 5 minutos, só se você adicionar máquinas.")
                item("arrow.down.circle", "Para o GitHub", "Uma consulta por dia para saber se há versão nova.", divider: false)
            }
        }
    }

    private func item(_ symbol: String, _ title: String, _ text: String, divider: Bool = true) -> some View {
        SettingRow(title, detail: text, symbol: symbol, divider: divider) { EmptyView() }
    }
}

/// Pomodoro e onde a contagem aparece. Mudar um tempo vale a partir da próxima fase.
struct ToolsSettings: View {
    @AppStorage(Prefs.Key.pomoFocus) private var focus = 25
    @AppStorage(Prefs.Key.pomoShort) private var short = 5
    @AppStorage(Prefs.Key.pomoLong) private var long = 15
    @AppStorage(Prefs.Key.pomoLongEvery) private var every = 4
    @AppStorage(Prefs.Key.pomoAutoNext) private var autoNext = true
    @AppStorage(Prefs.Key.timerWhere) private var place = "both"
    @AppStorage(Prefs.Key.timerFront) private var front = true

    var body: some View {
        SettingsPage(symbol: "wrench.and.screwdriver.fill", title: "Ferramentas", subtitle: "Tempos do pomodoro e onde a contagem aparece.") {
            GlassSection("Pomodoro", footer: "Um tempo novo vale a partir da próxima fase. A fase que já está rodando não muda.") {
                SettingRow("Foco: \(focus) min") { Stepper("", value: $focus, in: 1...180).labelsHidden() }
                SettingRow("Pausa: \(short) min") { Stepper("", value: $short, in: 1...180).labelsHidden() }
                SettingRow("Pausa longa: \(long) min") { Stepper("", value: $long, in: 1...180).labelsHidden() }
                SettingRow("Pausa longa a cada \(every) focos") { Stepper("", value: $every, in: 1...12).labelsHidden() }
                SettingRow("Começar a próxima fase sozinho", detail: "Desligado, a fase seguinte espera você apertar o play.", divider: false) {
                    Toggle("", isOn: $autoNext).labelsHidden()
                }
            }
            GlassSection("Contagem do pomodoro e do cronômetro") {
                SettingRow("Onde aparece") {
                    Picker("", selection: $place) {
                        Text("Barra e orelha").tag("both"); Text("Barra de menus").tag("menu"); Text("Orelha").tag("ear")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }
                SettingRow("Passar à frente na orelha", detail: "Ligado, a contagem aparece primeiro na orelha. Rolar mostra os outros itens.", divider: false) {
                    Toggle("", isOn: $front).labelsHidden()
                }
            }
        }
    }
}
