# Testes no iPhone fisico

Este documento descreve como um agente (Codex, Claude ou uma pessoa no Terminal)
compila o FeedMine, instala no iPhone conectado e opera o app por meio de testes
XCUITest.

## O que significa "operar o celular"

O Mac nao tem um controle remoto generico da tela do iPhone. O fluxo combina
duas ferramentas da Apple:

- `xcrun devicectl`: descobre o aparelho, consulta seu estado, instala, abre e
  remove o app.
- XCUITest: toca em botoes, faz gestos, digita, consulta a arvore de
  acessibilidade, mede transicoes e salva screenshots.

Portanto, uma exploracao automatizada deve existir como um teste em
`feedmineUITests/`. O agente executa esse teste no aparelho e le o resultado e
as imagens no arquivo `.xcresult`. Sem um XCUITest, o agente consegue abrir o
app, acompanhar o console e pedir que uma pessoa descreva a tela, mas nao
consegue tocar livremente nela.

## Pre-requisitos

No iPhone:

1. Conectar por USB e aceitar `Confiar neste computador`.
2. Ativar o Developer Mode.
3. Manter o aparelho desbloqueado e com a tela ligada durante o teste.
4. Verificar que o aparelho tem acesso a internet. Os feeds sao baixados pelo
   proprio iPhone.
5. Fechar alertas de sistema pendentes, como autorizacao de desenvolvedor ou
   confirmacao de senha.

No Mac:

- Xcode e Command Line Tools instalados.
- Signing automatico disponivel para o time configurado no projeto.
- Executar os comandos a partir da raiz do repositorio.
- Nao regenerar `feedmine.xcodeproj` com XcodeGen. O projeto contem ajustes e
  dependencias adicionados diretamente.

## 1. Encontrar o aparelho

Nunca copie um identificador antigo de um documento ou do `Makefile`. O
identificador CoreDevice pode mudar. Consulte o aparelho conectado:

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine
xcrun devicectl list devices
```

Escolha a linha do iPhone que esteja `available (paired)` e exporte o valor da
coluna `Identifier`:

```bash
export FEEDMINE_DEVICE_ID="<IDENTIFIER_DO_IPHONE>"
```

Confirme que ele esta desbloqueado e que o display esta ativo:

```bash
xcrun devicectl device info lockState --device "$FEEDMINE_DEVICE_ID"
xcrun devicectl device info displays --device "$FEEDMINE_DEVICE_ID"
```

O primeiro comando deve informar `unlockedSinceBoot: true`; o segundo deve
mostrar o backlight ativo.

## 2. Compilar, instalar e abrir

O caminho recomendado usa os alvos existentes no `Makefile`, sempre passando o
identificador descoberto no passo anterior:

```bash
make build DEVICE="$FEEDMINE_DEVICE_ID"
make install DEVICE="$FEEDMINE_DEVICE_ID"
make launch DEVICE="$FEEDMINE_DEVICE_ID"
```

O ciclo completo pode ser executado de uma vez:

```bash
make all DEVICE="$FEEDMINE_DEVICE_ID"
```

Os comandos equivalentes, sem o `Makefile`, sao:

```bash
xcodebuild build \
  -project feedmine.xcodeproj \
  -scheme feedmine \
  -configuration Debug \
  -destination "platform=iOS,id=$FEEDMINE_DEVICE_ID" \
  -allowProvisioningUpdates \
  -derivedDataPath .build-device

xcrun devicectl device install app \
  --device "$FEEDMINE_DEVICE_ID" \
  .build-device/Build/Products/Debug-iphoneos/feedmine.app

xcrun devicectl device process launch \
  --device "$FEEDMINE_DEVICE_ID" \
  --terminate-existing \
  com.feedmine.app
```

Para abrir o app e acompanhar seu console, use `--console`. Esse comando fica
ativo ate o app terminar ou ate receber `Ctrl+C`:

```bash
xcrun devicectl device process launch \
  --device "$FEEDMINE_DEVICE_ID" \
  --terminate-existing \
  --console \
  com.feedmine.app
```

## 3. Escolher o estado inicial

O estado inicial faz parte do experimento e deve ser anotado no resultado.

### Instalacao limpa

Remove banco, cache e `UserDefaults`. Use para testar primeira abertura,
onboarding e cold start real:

```bash
xcrun devicectl device uninstall app \
  --device "$FEEDMINE_DEVICE_ID" \
  com.feedmine.app

make build install DEVICE="$FEEDMINE_DEVICE_ID"
```

### Cold start preservando dados

Encerre e abra novamente o processo sem remover o app. Isso preserva filtros,
banco e cache, mas cria um novo processo:

```bash
xcrun devicectl device process launch \
  --device "$FEEDMINE_DEVICE_ID" \
  --terminate-existing \
  com.feedmine.app
```

### Warm start

Abra o app que ja esta instalado e preserve seu processo ou estado recente.
Este cenario mede a experiencia cotidiana, mas nao deve ser confundido com a
primeira abertura.

## 4. Executar testes no aparelho

### Unitarios

```bash
make test-device DEVICE="$FEEDMINE_DEVICE_ID"
```

O alvo do `Makefile` e conveniente para leitura humana, mas filtra a saida e
termina com `|| true`. Ele nao deve ser usado sozinho para afirmar que a suite
passou. Para uma verificacao formal, use o `xcodebuild` abaixo e confira seu
exit code e o `.xcresult`.

Comando completo:

```bash
xcodebuild test \
  -project feedmine.xcodeproj \
  -scheme feedmine \
  -configuration Debug \
  -destination "platform=iOS,id=$FEEDMINE_DEVICE_ID" \
  -allowProvisioningUpdates \
  -derivedDataPath .build-device \
  -only-testing:feedmineTests
```

### Interface completa

```bash
make test-ui DEVICE="$FEEDMINE_DEVICE_ID"
```

### Um teste de interface especifico

Salvar o `.xcresult` e importante: ele contem screenshots, logs, duracoes e a
arvore de atividades do teste.

```bash
mkdir -p build/physical-results
RESULT="build/physical-results/filter-latency-$(date +%Y%m%d-%H%M%S).xcresult"

xcodebuild test \
  -project feedmine.xcodeproj \
  -scheme feedmine \
  -configuration Debug \
  -destination "platform=iOS,id=$FEEDMINE_DEVICE_ID" \
  -allowProvisioningUpdates \
  -derivedDataPath .build-device \
  -resultBundlePath "$RESULT" \
  -only-testing:feedmineUITests/FeedmineUITests/testContentTypeFilterTapsRespondImmediately
```

Para repetir sem recompilar, depois de uma execucao bem-sucedida:

```bash
xcodebuild test-without-building \
  -project feedmine.xcodeproj \
  -scheme feedmine \
  -destination "platform=iOS,id=$FEEDMINE_DEVICE_ID" \
  -derivedDataPath .build-device \
  -only-testing:feedmineUITests/FeedmineUITests/testContentTypeFilterTapsRespondImmediately
```

### Cenarios de uso existentes: filtros

As automacoes de filtros ficam em dois arquivos:

- `feedmineUITests/FeedmineFilterUITests.swift`: operacao e responsividade da
  janela de filtros.
- `feedmineUITests/FeedmineUITests.swift`: aplicacao de filtros e verificacao do
  conteudo que aparece no feed.

Use o mesmo comando da secao anterior e troque o valor de `-only-testing` por
um dos identificadores abaixo.

| Cenario | Identificador XCUITest | O que observar |
|---|---|---|
| Selecionar Videos | `feedmineUITests/FeedmineFilterUITests/testContentTypeVideoSelectionCompletesUnder1Second` | Tempo do toque e estado selecionado |
| Percorrer todos os tipos | `feedmineUITests/FeedmineFilterUITests/testContentTypeAllSelectionsRespondQuickly` | Latencia de All, Articles, Videos, Podcasts e Forums |
| Videos + English | `feedmineUITests/FeedmineFilterUITests/testVideoFilterWithEnglishLanguage` | Chips, cards e screenshot `video-en-filter` |
| Articles + Portuguese | `feedmineUITests/FeedmineFilterUITests/testArticlesFilterWithPortugueseLanguage` | Selecao combinada e cards resultantes |
| Alternancia rapida | `feedmineUITests/FeedmineFilterUITests/testRapidContentTypeTogglesDontBlockUI` | Bloqueio da UI durante varias trocas |
| Fechar e reabrir | `feedmineUITests/FeedmineFilterUITests/testFilterSelectionSurvivesDismissAndReopen` | Persistencia da selecao |
| Filtro de mood | `feedmineUITests/FeedmineFilterUITests/testMoodFilterSelectionRespondsQuickly` | Localizacao e resposta do controle |
| Limpar tudo | `feedmineUITests/FeedmineFilterUITests/testClearAllFiltersRemovesAllSelections` | Remocao das selecoes e fechamento do sheet |
| Matriz de tipos | `feedmineUITests/FeedmineFilterUITests/testFilterCombinationsMatrix` | Cards depois de All, Articles, Videos e Podcasts |
| Topico Acoustics | `feedmineUITests/FeedmineUITests/testAcousticsFilterShowsAcousticsCards` | Conteudo esperado e ausencia de CNN/BBC |
| Categoria com uma fonte | `feedmineUITests/FeedmineUITests/testSingleFeedCategoryShowsCard` | Resultado de Greek & Roman Mythology |
| Categoria de podcast | `feedmineUITests/FeedmineUITests/testPodcastCategoryShowsCards` | Cards de humor sem fontes gerais |
| Categoria de video | `feedmineUITests/FeedmineUITests/testVideoCategoryShowsCards` | Canais de culinaria sem fontes gerais |
| Pais | `feedmineUITests/FeedmineUITests/testCountryCategoryShowsCards` | Cards relacionados a Algeria |
| Categoria grande | `feedmineUITests/FeedmineUITests/testManyFeedsCategoryShowsCards` | Diversidade de Photography News & Reviews |
| Limpar e restaurar feed | `feedmineUITests/FeedmineUITests/testClearFiltersRestoresFullFeed` | Sheet fecha e feed volta ao estado geral |

Exemplo para reproduzir o caso Videos + English no iPhone:

```bash
mkdir -p build/physical-results
RESULT="build/physical-results/videos-en-$(date +%Y%m%d-%H%M%S).xcresult"

xcodebuild test \
  -project feedmine.xcodeproj \
  -scheme feedmine \
  -configuration Debug \
  -destination "platform=iOS,id=$FEEDMINE_DEVICE_ID" \
  -allowProvisioningUpdates \
  -derivedDataPath .build-device \
  -resultBundlePath "$RESULT" \
  -only-testing:feedmineUITests/FeedmineFilterUITests/testVideoFilterWithEnglishLanguage
```

Para uma rodada de regressao dos problemas de filtro relatados no aparelho,
comece com uma instalacao limpa e execute nesta ordem:

1. `testContentTypeAllSelectionsRespondQuickly`
2. `testRapidContentTypeTogglesDontBlockUI`
3. `testVideoFilterWithEnglishLanguage`
4. `testArticlesFilterWithPortugueseLanguage`
5. `testFilterSelectionSurvivesDismissAndReopen`
6. `testClearAllFiltersRemovesAllSelections`
7. `testVideoCategoryShowsCards`
8. `testCountryCategoryShowsCards`
9. `testClearFiltersRestoresFullFeed`

Os testes de `FeedmineFilterUITests` foram escritos inicialmente como testes
diagnosticos. Alguns caminhos registram `warning` e continuam, e parte das
medicoes cronometra o retorno de `tap()`. Eles sao uteis para operar e observar
o aparelho, mas o `.xcresult` e os screenshots ainda devem ser inspecionados.
As classes tambem nao zeram todos os filtros persistidos antes de cada metodo;
ao investigar um caso isolado, remova o app antes da execucao ou garanta que o
teste limpe explicitamente o estado que criou.
Para transformar um relato em criterio de aceite, adicione uma assercao sobre o
estado visual ou o conjunto de cards esperado, conforme a proxima secao.

## 5. Como escrever uma operacao automatizada

Use identificadores de acessibilidade, nao coordenadas de tela. O FeedMine ja
expoe, entre outros:

- `filter-button`
- `filter-done`
- `content-type-videos`
- `browse-topics`
- `search-topics`
- `topics-done`

Exemplo reduzido:

```swift
@MainActor
func testVideosFilterOnPhysicalDevice() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)"]
    app.launch()

    let filter = app.buttons["filter-button"]
    XCTAssertTrue(filter.waitForExistence(timeout: 40))
    filter.tap()

    let videos = app.buttons["content-type-videos"]
    XCTAssertTrue(videos.waitForExistence(timeout: 5))
    videos.tap()

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "physical-videos-selected"
    screenshot.lifetime = .keepAlways
    add(screenshot)
}
```

Ao medir responsividade, nao cronometre apenas o retorno de `tap()`. Aguarde um
efeito observavel, como mudanca de `value`, surgimento de um elemento ou
desaparecimento de um loading state, e meca ate esse ponto. Caso contrario, o
teste mede somente o envio do evento, nao a resposta visual percebida.

## 6. Ler resultados e screenshots

Resumo do teste:

```bash
xcrun xcresulttool get test-results summary --path "$RESULT"
```

Exportar todas as imagens e anexos:

```bash
ATTACHMENTS="${RESULT%.xcresult}-attachments"
xcrun xcresulttool export attachments \
  --path "$RESULT" \
  --output-path "$ATTACHMENTS"
```

O diretorio exportado inclui `manifest.json`, que relaciona cada arquivo ao
teste e ao nome definido no `XCTAttachment`.

## 7. Roteiro exploratorio recomendado

Para investigar um relato feito no aparelho:

1. Reproduzir manualmente e anotar estado inicial, idioma, filtros e rede.
2. Identificar os elementos envolvidos e seus accessibility identifiers.
3. Criar um XCUITest curto que reproduza exatamente os gestos relatados.
4. Fazer uma execucao em instalacao limpa.
5. Repetir em cold start preservando dados.
6. Guardar screenshots antes e depois da acao critica.
7. Registrar tempo ate a mudanca visual, nao apenas tempo de `tap()`.
8. Corrigir o codigo e repetir o mesmo teste no mesmo aparelho.
9. Rodar a suite unitaria relacionada para detectar regressao de logica.

Para problemas de scroll, repeticao e carregamento progressivo, o teste deve
tambem registrar os primeiros cards visiveis e seus `sourceID`/labels antes e
depois de cada gesto. Uma imagem sozinha nao prova diversidade nem ausencia de
duplicatas.

## 8. Problemas comuns

### O aparelho aparece como indisponivel

- Desbloqueie a tela.
- Confirme a mensagem de confianca no iPhone.
- Desconecte e reconecte o USB.
- Abra o Xcode uma vez para concluir o pareamento e preparar o Developer Disk
  Image.
- Execute novamente `xcrun devicectl list devices`.

### Falha de signing ou provisioning

Use `-allowProvisioningUpdates`, confirme que a conta esta autenticada no Xcode
e que o time `955573A4YH` continua valido para esta maquina.

### O teste toca no elemento errado ou nao encontra o botao

- Verifique se o aparelho esta no idioma esperado.
- Prefira `accessibilityIdentifier` a texto localizado.
- Use `waitForExistence` e `isHittable`; nao substitua sincronizacao por varios
  `sleep` longos.
- Confirme se um sheet, teclado ou alerta do sistema esta cobrindo a tela.

### O app abre com dados inesperados

Reinstalar por cima preserva dados. Para uma instalacao realmente zerada,
execute `devicectl device uninstall app` antes de instalar novamente.

### O resultado no iPhone difere do simulador

Isso e esperado para rede, desempenho, memoria, armazenamento, cache e timing
de gestos. O simulador continua util para iteracao rapida, mas a validacao final
de cold start, fluidez e carregamento progressivo deve usar o aparelho fisico.

## 9. Checklist para registrar uma conclusao

- Modelo e versao do iOS.
- Identificador do aparelho usado na execucao.
- Commit ou estado do working tree.
- Instalacao limpa, cold start ou warm start.
- Idioma e filtros ativos.
- Nome exato do teste executado.
- Resultado `.xcresult` preservado.
- Screenshots antes e depois.
- Duracao da transicao observavel.
- Logs ou mensagem de falha relevantes.
