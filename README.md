# iLand

O iLand mora no notch do Mac. Ele mostra a temperatura, o uso do Claude ou do Codex, timers, a página Hoje e um
assistente que conhece o seu dia. Os seus dados ficam no seu Mac. Nenhum dado vai para um servidor da Loop.

Requisito: Mac com chip Apple (M1 ou mais novo).

## Licença

O código original do iLand é distribuído sob a [licença MIT](LICENSE).
Você pode usar, modificar, distribuir e vender cópias, inclusive em produtos fechados,
desde que preserve o aviso de copyright e o texto da licença nas cópias ou partes substanciais.
O software é fornecido sem garantia, nos termos da licença.

Componentes de terceiros mantêm suas próprias licenças. Consulte
[os avisos de componentes e serviços](THIRD_PARTY_NOTICES.md).
O build inclui esses documentos no aplicativo distribuído.

## O que o iLand faz

- **Orelhas do notch**: o uso de 5 h e 7 dias do Claude ou do Codex, o pomodoro, o cronômetro e os alertas.
- **Vista rápida** (mouse no notch): temperatura, processos pesados, som, ferramentas (cafeína, cronômetro,
  pomodoro), atalhos, captura de tela, área de transferência, prateleira de arquivos, notas, pergunta rápida ao
  modelo, máquinas e a página Hoje.
- **Visão geral**: todos os processos, por app e em árvore, gráficos de energia e portas abertas. Encerrar um
  processo sempre pede confirmação.
- **Hoje**: o tempo do dia por app e por projeto, o "onde parei" quando você volta a um projeto e o resumo do dia.
- **Assistente** (⌃⌥⌘Espaço): conversa com o modelo que você escolher. Ele consulta o seu dia, os projetos, o
  timer e as tasks do ClickUp. Ele só abre um projeto no editor sozinho. Parar timer, guardar nota ou guardar na
  memória sempre esperam o seu "Aprovar".
- **Vigia do timer do ClickUp**: avisa quando o timer roda numa task e você está em outro projeto, ou longe do Mac.
- **Máquinas** (opcional): CPU, memória e disco de servidores Linux por SSH, a cada 5 minutos.

## O que o iLand lê e o que sai do Mac

O iLand lê, e guarda só neste Mac:

- **Apps e janelas**: o app em uso, o título da janela e o arquivo aberto (Acessibilidade). Janela anônima, campo
  de senha e tela bloqueada não têm o título salvo. O registro fica 30 dias. O botão **Pausar** da página Hoje
  para o registro.
- **Sessões do Claude Code e do Codex**: a pasta, o horário e o último pedido de cada sessão, com senhas
  mascaradas. As conversas do app do Claude (chat) não ficam no Mac, então o iLand não vê nada delas. Dá para
  desligar em **Ajustes › Privacidade**.
- **Projetos com git**: os arquivos alterados, os commits do dia e a seção "Em progresso" do `docs/ESTADO.md`.
- **Área de transferência**: as últimas 50 coisas copiadas. Senhas de gerenciadores não entram.
- **Processos e sensores**: CPU, memória, disco, bateria e temperatura.
- **Contas**: o login do Claude Code (só para ler o uso) e o token do ClickUp, no Keychain.

O que sai do Mac:

- **Para o modelo que você escolher** (Anthropic, OpenAI ou Ollama cloud): a sua pergunta, o contexto do dia e o
  que as ferramentas leem (títulos de janela, projetos, tasks). Com um modelo local do Ollama, nada sai.
- **Para o ClickUp**: a leitura das suas tasks e do timer.
- **Para as suas máquinas**: um SSH de leitura, só se você adicionar máquinas.
- **Para o GitHub**: uma consulta por dia para saber se há versão nova.

Nenhum dado vai para um servidor da Loop. A configuração inicial mostra esta mesma lista antes de qualquer
permissão.

## Instalar

1. Baixe o `iLand.dmg` da última versão em **Releases** deste repositório.
2. Abra o `.dmg` e arraste o iLand para **Aplicativos**.
3. Abra o iLand. O macOS bloqueia na primeira vez, porque o app não é da App Store.
4. Vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o aviso do iLand e clique em **Abrir Mesmo Assim**.
5. O assistente de configuração abre. Siga os passos. Todos podem ser pulados.

Você só libera o app uma vez. As versões novas instalam pelo próprio iLand (menu do ícone › **Atualizar**) e
mantêm as permissões.

## Permissões

- **Acessibilidade** (no macOS 27: "Controle do Dispositivo e Acesso a Dados"): para saber em que app e projeto
  você está. Sem ela, a página Hoje e o assistente sabem menos do seu dia.
- **Automação** (o macOS pergunta na hora): para abrir a aba certa do Terminal e saber se o Chrome ou o Arc estão
  em janela anônima.

## Modelos

Em **Ajustes › Modelos** você conecta o que tiver e escolhe quem faz cada tarefa:

- **Claude Code**: o `claude` instalado e logado.
- **Codex**: o `codex` instalado e logado (`codex login`).
- **Ollama**: o app aberto. Modelos cloud precisam de `ollama signin`.

O iLand usa o login de cada ferramenta e não guarda chave de API.

## Para quem desenvolve

```bash
./build.sh          # gera o iLand.app
./build.sh --dmg    # gera também dist/iLand.dmg
./install.sh        # compila e instala em /Applications
```

Sem o certificado "iLand Loop Signing", o build sai com assinatura ad-hoc e o macOS pede as permissões a cada
build. Para usar no dia a dia, instale a versão do Releases.

### Publicar uma versão

1. Abra um PR. O mantenedor revisa e faz o merge.
2. Crie a tag: `git tag v1.2.0 && git push origin v1.2.0`.
3. O GitHub Actions compila, assina e publica o `iLand.dmg` no Releases. Os apps instalados avisam da versão nova.

Os secrets `ILAND_SIGNING_P12` e `ILAND_SIGNING_PASSWORD` guardam o certificado. Todas as versões têm de sair com
o mesmo certificado. Se ele mudar, cada pessoa tem de liberar o app e dar as permissões de novo.
