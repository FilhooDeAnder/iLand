# Testes

Execute todos os testes automatizados na raiz do checkout:

```bash
./scripts/test.sh
```

- `Unit/`: regras, parsers e resolução de recursos; execute com `scripts/test_unit.sh`.
- `Fixtures/`: apenas dados sintéticos, sem registros reais de atividade.
- `Diagnostics/`: diagnósticos manuais de tela e notch; não fazem parte da suíte automatizada.
- `Manual/test_app.sh`: compila e abre o app; encerra a instância atual do iLand.

A suíte de captura (`scripts/test_capture.sh`) cobre composição, edição, exportação e S3.
Os scripts encontram a raiz pelo próprio caminho e podem ser chamados de outro diretório.
