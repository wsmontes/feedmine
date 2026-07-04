# FeedMine Circadian Design System

## Concept

O FeedMine ganha um design system que respira com o dia. Sem mudanças estruturais pesadas — o app continua o mesmo, mas paleta, tipografia, densidade e micro-interações se adaptam ao horário. A mudança é sutil, quase subliminar: quem usa o app às 7h e às 23h sente atmosferas diferentes sem conseguir apontar exatamente o quê.

**Princípio:** dados internos apenas. Nada de weather, localização ou API externa. O app usa o que já sabe.

## 1. Ritmo Circadiano — 5 Períodos

| Período | Horário | Accent | Peso fonte | Letter-spacing | Line-height | Densidade |
|---------|---------|--------|-----------|---------------|-------------|-----------|
| 🌅 Dawn | 5–8h | Coral `#E87461` | Light | +0.3pt | 1.50 | Arejado |
| ☀️ Morning | 8–12h | Âmbar `#D4874B` | Regular | 0 | 1.45 | Confortável |
| 🔆 Afternoon | 12–17h | Terracota `#C4613D` | Medium | −0.1pt | 1.35 | Confortável |
| 🌅 Evening | 17–21h | Cobre `#B8653A` | Regular | +0.1pt | 1.50 | Generoso |
| 🌙 Night | 21–5h | Bronze `#8B6F5C` | Light | +0.5pt | 1.55 | Respirando |

Cada período aplica seu pacote a: accent color (tint, links, badges), `page-bg` (matiz sutil), densidade de cards (padding, gap), peso e spacing da fonte.

## 2. Paleta Base (fixa)

```
page-bg:       #FAF8F5  (creme quente)
card-bg:       #FFFFFF  (branco)
text-primary:  #1C1B1A  (quase-preto quente)
text-secondary:#6B6560  (cinza quente)
text-tertiary: #9E9790  (cinza claro)
separator:     #E8E4DF  (bege borda)
```

Cores de categoria dessaturadas para harmonizar:

```
tech    → #5B7FA5 (azul acinzentado)
news    → #B8685C (vermelho terroso)
science → #6B9E7A (verde musgo)
design  → #8B7BA8 (violeta suave)
culture → #C4854A (laranja queimado)
```

## 3. Cinco Famílias de Paleta Circadiana

Selecionáveis nas Settings → Appearance → Palette Family. Warm Earth é default.

### A · Warm Earth (padrão)
Coral → Âmbar → Terracota → Cobre → Bronze
Acolhedor, tátil, como cerâmica e papel artesanal.

### B · Cool Sky
`#7BA4C4` → `#5B8FAD` → `#4A7C9B` → `#3D5F80` → `#2C3E5A`
Fresco, nítido, como o céu ao longo do dia.

### C · Botanical
`#7AAA7A` → `#5E9465` → `#4A7A4A` → `#3D5E3D` → `#2E4A2E`
Orgânico, verde, como um jardim.

### D · Lavender Hour
`#B8A4C8` → `#9B82B5` → `#7E5F9E` → `#684C8A` → `#4A3570`
Etéreo, suave, violetas e lilases.

### E · Monochrome
`#B0A89E` → `#9E9690` → `#8C8580` → `#7A7370` → `#686260`
Sóbrio, atemporal, tons de cinza quente. Para quem quer o ritmo sem cor.

### Settings
- Toggle "Adaptive Palette" (on/off, default on). Off → usa âmbar fixo (manhã).
- Picker "Palette Family" com 5 opções.
- Toggle "Adaptive Typography" (on/off, default on). Off → SF Regular fixo.
- Picker "Font Style": System (circadian weight variation) | New York (serif editorial) | SF Mono (técnico).

## 4. Tipografia

### Comportamento padrão (System, adaptive on)

A fonte é sempre San Francisco. O que muda é **peso, letter-spacing e line-height** conforme o período. A variação é sutil — o usuário sente mas não identifica conscientemente.

- Títulos de card: SF 17pt, peso variável por período
- Corpo/excerpt: SF 13-14pt, Regular
- Metadados: SF 11-12pt, Regular
- MomentCard: `.subheadline`, peso variável por período
- Cabeçalhos de seção: SF 13pt, peso variável + cor do período
- UI (botões, sheets, settings): SF, peso padrão do sistema

### Font size ajustável mantido

Small / Medium / Large escala proporcionalmente.

### Font Style opcional

- **New York**: serif editorial nos títulos de card, MomentCard e cabeçalhos de seção. SF no corpo.
- **SF Mono**: monoespaçado técnico/brutalista. Visual de terminal.

## 5. Layout Responsivo

### Portrait → Card Vertical
- Imagem hero 16:9 (igual ao atual)
- Padding: 14px (manhã/tarde), 16px (dawn), 18px (evening), 22px (night)
- Gap entre cards: 10px (tarde), 12px (manhã), 14px (evening), 16px (dawn), 18px (night)

### Landscape → Card Horizontal
- Thumb 90×90 à esquerda, radius 8px
- Texto à direita: título + 2 linhas excerpt + metadata
- Padding: 12px interno, 8px gap entre cards
- Mantém tipografia e cor do período

### Regra
Se `largura da tela > altura` → horizontal. Senão → vertical.
iPad em portrait com Magic Keyboard continua usando card vertical (coluna única é confortável).

### Card refinements (fixos, todos períodos)
- Sem stroke `separator 0.5` — substituído por sombra sutil (`shadow color black 0.04 radius 8 y 2`)
- Border radius: 14px
- Indicador de não lido: dot 5px na cor do período, canto superior direito do card (substitui barra lateral de 3px)

## 6. MomentCard — Motor de Frases Expandido

### Visual
Inalterado: texto `.subheadline`, alinhado à esquerda, padding 16px horizontal. Nada de gradiente, ícone grande, ou weather. A melhoria é puramente no texto.

### Dados utilizados (internos apenas)
- **Tempo:** hora, timeOfDay, weekday, weekend, month, season, specialDate, holiday
- **Feed:** totalItems, unreadCount, sourceCount, podcastCount, youtubeCount, newSinceLastOpen, topCategories, lastRefreshDate
- **Leitura:** readCount, bookmarkCount, streakDays, articlesThisSession, readingPace, sessionMinutes
- **Padrões:** routineMatch, avgOpeningHour, daysWithApp, isFirstOpenToday, isWeekendReader, isNightOwl

### 14 Tipos de Slot
`[greeting]` `[weekday]` `[season]` `[count]` `[sources]` `[streak]` `[session]` `[pace]` `[routine]` `[content]` `[special]` `[podcast]` `[bookmarks]` `[tone]`

Cada slot é uma função que retorna texto baseado em dados, com 8–15 variações cada. Slots sem dados disponíveis são omitidos.

### 60+ Templates em 7 Grupos

1. **Abertura (10):** Dawn/manhã — "Good morning. 34 new stories, mostly tech and science."
2. **Leitura (10):** Session > 20 min — "12 min in. You're on a 3-day streak."
3. **Noite (8):** 21–5h — "Quiet hours. 8 articles, no rush."
4. **Podcast (8):** Podcasts disponíveis — "3 podcasts ready, 12 to read."
5. **Streak (8):** Streak > 3 dias — "7-day streak. Consistency is the superpower."
6. **Datas especiais (8):** Feriados e datas comemorativas.
7. **Tom leve (8):** Fallback — "No algorithm. No ads. Just 34 stories from 12 sources."

### Lógica de Seleção
1. Prioridade: special date > night > dawn/morning > session > podcasts > streak > fallback
2. Preenche slots com dados disponíveis
3. Escore por completude (mais slots = prioridade)
4. Random entre top 3 (evita repetição)
5. Anti-repetição: mesmo template não se repete em < 2 horas
6. Refresh a cada 30s. Muda quando contexto mudar.

## 7. Micro-interações & Polimento

### Transição circadiana suave
Crossfade de 2s (`.easeInOut`) na cor do accent e `page-bg` quando o período muda.

### Haptics
- ✅ Já existem: tap no card, bookmark, scroll-to-top, shake-to-refresh
- ✨ Adicionar: pull-down atinge threshold da search (`.light`)
- ✨ Adicionar: swipe mark-read confirmação (`.light`)

### Scroll-to-top
Botão herda a cor do período (background usa accent a 12% em vez de `systemGray6`).

### Skeleton loading
Usa o `DreamyGradient` + `ScanningBeam` do WhatsNewCarousel — círculos animados com blur + scanning beam — adaptado para o formato retangular dos cards. A cor base do gradiente segue o período.

### Empty state
`ContentUnavailableView` padrão, mas com texto seguindo o tom do período. Ex: "Nothing here yet. Check back at sunrise?" (dawn) vs "All caught up. Sleep well." (night).

### Badge de não lido
Dot 5px na cor do período no canto superior direito do card. Substitui a barra lateral colorida de 3px.

## 8. Header

Simplificar a barra superior:
- Manter: greeting ("Feedmine ·12 sources ·34 fetched") + search + filters
- Mover para menu "..." ou sheet: Settings, Sources, Bookmarks

## 9. Edge Cases

- **Adaptive Palette off:** usa âmbar fixo (manhã), sem transições
- **Adaptive Typography off:** SF Regular fixo, sem variação de peso
- **Sem dados de padrão (first time user):** slots `[routine]` e `[streak]` omitidos
- **Feed vazio:** MomentCard mostra mensagem de boas-vindas, não template de contagem
- **Night mode ativo:** overlay escuro continua funcionando independente do sistema circadiano
- **Transição de período com app em background:** aplica na próxima entrada em foreground
- **Landscape → Portrait (rotação):** cards reconstroem com layout correto, sem animação brusca

## 10. O Que Não Muda

- Arquitetura do FeedLoader
- Navegação (sheets, article reader)
- Funcionalidades (bookmarks, search, filtros, podcast player, shake-to-refresh)
- OnboardingTipsView
- DebugStatusBar
- MiniPlayerBar
- Settings (apenas ganha novas opções)
- Cores de categoria (apenas dessaturadas)
