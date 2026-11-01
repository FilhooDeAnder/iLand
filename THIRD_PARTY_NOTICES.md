# Componentes e serviços de terceiros

A licença MIT na raiz cobre o código original do iLand. Ela não substitui
licenças de componentes de terceiros nem os termos dos serviços integrados.

## Executável sensors — componente próprio

O executável arm64 `Resources/sensors`, copiado para o aplicativo por `scripts/build.sh`, foi criado
por Anderson Carvalho, conforme confirmação do autor em 31 de outubro de 2026.
Ele é distribuído sob a mesma [licença MIT](LICENSE) do iLand.

O código-fonte desse executável ainda não está presente neste repositório.

## Dependências e integrações

`Package.swift` não declara pacotes externos. O aplicativo usa frameworks do macOS.
As integrações com Claude Code, Codex, Ollama, ClickUp, GitHub e outros serviços
continuam sujeitas às licenças e aos termos dos respectivos fornecedores.

## Referências de produto

Ideias de produto foram inspiradas no projeto vorssaint-utils (GPL-3.0).
A implementação deve ser independente, sem copiar código incompatível com a MIT.
Esta nota não é uma auditoria de procedência de todos os arquivos do iLand.

Ao incorporar código ou assets de terceiros, registrar aqui a origem, a licença
e os avisos aplicáveis, preservando os textos exigidos pelo titular.
