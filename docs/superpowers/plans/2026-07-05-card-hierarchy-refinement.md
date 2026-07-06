# FeedMine Card Hierarchy & Visual Refinement — Plano

## Contexto

5 melhorias de design que corrigem hierarquia visual, removem decoração falsa, e dão presença ao MomentCard. Nenhuma muda arquitetura — só layout de card e tipografia.

---

### 1. Source-first card hierarchy

**Arquivo:** `FeedItemCardView.swift`

- [ ] Mover source name para antes da categoria na row de metadata
- [ ] Source name: `.caption` → `.subheadline`, `.secondary` → `.primary`, `.fontWeight(.medium)`
- [ ] Categoria: remover cápsula colorida. Substituir por borda esquerda de 3px no card, cor da categoria
- [ ] Remover `unreadDot` do canto superior — a borda esquerda já indica novidade (cor mais viva = não lido, cor atenuada = lido)
- [ ] `isRead`: borda esquerda usa `categoryColor.opacity(0.3)` em vez de `categoryColor`

**Antes:** `[TECH] · Stratechery` — categoria grita, source sussurra  
**Depois:** `Stratechery` — source fala, borda colorida sutil organiza

---

### 2. Reading time > publish time

**Arquivo:** `FeedItemCardView.swift`

- [ ] Row de meta: `"4 min read"` em `.caption` `.fontWeight(.medium)` `.foregroundStyle(engine.accent)`
- [ ] Data: `.caption2` `.foregroundStyle(.tertiary)`, sem "·" — espaço ou `Spacer()` entre
- [ ] Remover `"·"` entre reading time e publish time
- [ ] Manter `formattedDate()` como está (relative para < 7 dias, date curta para antigo)

**Antes:** `2 hours ago · 4 min read` — peso igual  
**Depois:** `4 min read  2 hours ago` — o que importa primeiro

---

### 3. Remove shadow, use background tint

**Arquivo:** `FeedItemCardView.swift`

- [ ] Remover `.shadow(color: .black.opacity(0.04), radius: 8, y: 2)`
- [ ] Background do card: `Color(.systemBackground)` → `engine.accent.opacity(0.04)` (matiz sutil do período)
- [ ] Page background (`FeedScreen`): já é `engine.pageBackground` — contraste sutil entre card e página
- [ ] Border radius mantido (`engine.cardRadius`)

**Antes:** Card flutua com sombra  
**Depois:** Card se separa por tom, não por elevação. Mais página, menos widget.

---

### 4. Text-only cards: no fake placeholder

**Arquivo:** `FeedItemCardView.swift`

- [ ] Quando `item.bestImageURL == nil && item.imageURL == nil`: pular área de imagem
- [ ] Card sem imagem: bloco compacto. Source → título → excerpt → meta. Sem 180pt de gradiente.
- [ ] Borda esquerda de 3px + padding normal
- [ ] Se `imageLoadFailed == true`: recolher para modo texto (já existe a flag, só precisa mudar o layout)
- [ ] Manter a imagem 16:9 normalmente quando existir

**Antes:** Gradiente placeholder 180pt fingindo imagem  
**Depois:** Se não tem imagem, não ocupa espaço. Honesto.

---

### 5. MomentCard com presença sutil

**Arquivo:** `MomentCard.swift`

- [ ] Adicionar borda esquerda de 3px: `engine.accent` no `HStack`
- [ ] Padding vertical: 8 → 12
- [ ] Manter `.subheadline .secondary` — não vira card, não vira manchete
- [ ] Manter `frame(maxWidth: .infinity, alignment: .leading)`
- [ ] Borda aparece com animação sutil no onAppear (`.easeInOut 0.6s`)

**Antes:** Texto cinza invisível no scroll  
**Depois:** Texto com âncora visual sutil. Presente sem gritar.

---

## Ordem

| # | O quê | Arquivo | Minutos |
|---|-------|---------|---------|
| 1 | Source-first hierarchy | `FeedItemCardView.swift` | 15 |
| 2 | Reading time > publish | `FeedItemCardView.swift` | 5 |
| 3 | Remove shadow, bg tint | `FeedItemCardView.swift` | 5 |
| 4 | Text-only cards | `FeedItemCardView.swift` | 10 |
| 5 | MomentCard presence | `MomentCard.swift` | 5 |

**Total:** ~40min, 2 arquivos.

---

## Verificação

- Build: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination "platform=iOS Simulator,name=iPhone 14 Plus"` — 0 errors
- Visual: Card sem imagem → compacto, sem placeholder. Card com imagem → normal com borda esquerda.
- Source name visível e proeminente em todos os cards
- Reading time colorido, publish time apagado
- Sem sombra nos cards, tom de fundo sutil
- MomentCard visível com borda esquerda colorida
