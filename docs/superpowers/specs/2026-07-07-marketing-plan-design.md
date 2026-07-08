# feedmine — Plano de Marketing Digital

## Meta

- **Data:** 2026-07-07
- **Estágio:** Pré-lançamento
- **Orçamento:** US$ 100
- **Público:** Global, 40 línguas, iOS 18+
- **Monetização:** Gratuito (sem ads, sem assinatura)
- **Timeline:** 3 semanas até o lançamento

---

## Posicionamento

O feedmine não compete com Reeder ou NetNewsWire. Compete com Twitter, Instagram, TikTok.

O inimigo é o scroll infinito manipulado por algoritmo. O feedmine é o **substituto comportamental** — mesmo gesto motor (polegar scrollando), mesma recompensa (conteúdo novo), mas sem manipulação algorítmica.

O app não é apresentado como "mais um app". É apresentado como uma tentativa de resolver uma tensão real: a gente perdeu controle sobre como acessa e organiza informação.

---

## Duas vozes

| | Voz do produto (Instagram) | Voz do Wagner (nichos) |
|---|---|---|
| Quem fala | O feedmine | Wagner Montes |
| Tom | Absurdo, irônico, MTV, contradição | Pessoal, direto, honesto, fluxo de pensamento |
| Registro | "a gente" / impessoal | "eu" |
| Objetivo | Deixar a pulga atrás da orelha | Contribuir pra conversa |
| Regra | Piada seca, sem explicação, sem muleta | História real, sem polimento, sem IA mencionada |

### Regra das piadas

Toda piada tem lastro em algo que o código realmente faz. Nada inventado.

| Piada | Lastro real |
|---|---|
| "Esquecemos da backdoor" | Não tem backdoor porque não tem servidor — `PersistenceManager` salva local |
| "Queríamos coletar mas não temos pra onde mandar" | `FeedState` é um JSON no Documents folder, zlib, zero network |
| "Gastamos os tokens fazendo piada" | Não tem IA no app — MoodFilter é `lowercased().contains("crisis")` |
| "5 modos, indecisão do designer" | `CircadianPeriod` tem 5 casos. 5 paletas. |
| "Sem servidor = sem push" | Não tem backend |
| "Fase da lua com matemática juliana" | `computeMoonPhase` usa fórmula de data juliana |
| "O feed é infinito enquanto alguém publicar" | Não tem geração de conteúdo. Interleave round-robin. |
| "Seus dados: um JSON. No seu telefone." | `feedmine_state.json` + `feedmine_state.backup.json` |
| "Desenvolvedor responde de madrugada" | Wagner = 1 pessoa |

---

## Canal 1: Instagram — Voz do produto

### Reel — "Disclaimer"

```
"Este app foi feito majoritariamente por humanos."

"Contém falhas."

"Esquecemos da backdoor."

"Foi feito por uma pessoa."

"De madrugada."

"Que deveria estar dormindo."

"As cores foram escolhidas porque alguém gostou de um pôr do sol."

"O algoritmo não recomenda nada."

"Você vai ter que escolher o que ler."

"Sozinho."

"Sem um modelo te dizendo o que pensar."

"Boa sorte."
```

### Reel — "Nossos dados"

```
"Até queríamos coletar seus dados."

"Mas não temos pra onde mandar."

"Sem servidor."

"Sem cloud."

"Nem um Raspberry Pi."

"Seus dados: um arquivo JSON."

"No seu telefone."

"Se desinstalar, foi junto."

"Não nos agradeça."

"Não foi de propósito."

"Foi falta de orçamento."
```

### Reel — "Sem IA"

```
"Sem IA."

"Gastamos todos os tokens fazendo essas piadas."

"Nosso modelo:"

"0 parâmetros."

"0 dados de treinamento."

"0 viés."

"100% sua escolha."

"A gente chama de 'inteligência natural'."

"É você."

"Lendo."

"Decidindo."

"Desculpa o inconveniente."
```

### Reel — "Notificações"

```
"O feedmine nunca vai te mandar notificação."

[pausa longa]

"Não é filosofia."

"É incompetência."

"Sem servidor = sem push notification."

"A gente literalmente não tem como."

"Não tem backend."

"Não tem cloud."

"Não tem um estagiário mandando email."

[pausa]

"Tem um JSON."

"No seu telefone."

"Comprimido com zlib."

"Fim."
```

### Stories / Peças avulsas

- "Esquecemos de implementar a backdoor. Desculpa. Próxima versão."
- "Sem dark mode. Tem 5 modos. Um pra cada hora do dia. O designer não se decidiu."
- "97 países. A gente queria fofoca global."
- "Se você está vendo isso, nosso orçamento de targeting é zero. Você foi alcançado organicamente. Parabéns."
- "A única coisa que o feedmine recomenda é você ir dormir. Baseado na fase da lua. Calculada com matemática juliana. Não serve pra mais nada."
- "O feed é infinito. Enquanto alguém, em algum lugar, publicar algo que preste."
- "Este app foi testado em humanos. Principalmente no desenvolvedor. De madrugada."
- "Não pedimos review. Não pedimos like. Não pedimos share. A gente já pediu demais fazendo você ler isso."
- "Leia. Saia. Viva. O feedmine não vai te prender. A gente não sabe como."
- "Desculpa se você queria um algoritmo que te conhece melhor que você mesmo. Aqui é o contrário."
- "Nosso algoritmo de recomendação foi treinado em 0 dados. Resultado: zero viés. Zero bolha. Zero surpresa artificial."
- "O feedmine nunca vai te mandar um email pedindo pra voltar. Não temos seu email."
- "Atenção: conteúdo gerado majoritariamente por humanos."
- "Desculpe, a gente não vai decidir o que você vai ver. Você vai precisar escolher."
- "Furar a bolha? Que tal você criar a sua? Sem julgamentos."

### Carrossel — "Termos de uso" (5 slides)

```
Slide 1: "1. Você vai sentir falta do algoritmo."
         "Aquela sensação de que alguém decidiu por você."
         "Acabou."

Slide 2: "2. O feed é infinito."
         "Enquanto alguém publicar algo."
         "Quando os humanos pararem, ele para."
         "A gente não gera conteúdo."
         "Faltaram tokens."

Slide 3: "3. Seus dados não valem nada."
         "Pra gente. Porque a gente não coleta."
         "Pra você também, provavelmente."
         "Mas isso é entre você e você."

Slide 4: "4. As cores mudam sozinhas."
         "Você não controla."
         "A gente também não."
         "5 momentos do dia. 5 paletas."
         "Chama 'circadian engine' porque 'switch case' não vende."

Slide 5: "5. Não temos equipe de suporte."
         "Tem o desenvolvedor."
         "Ele lê os emails."
         "Às vezes responde."
         "Geralmente de madrugada."
```

### Calendário de postagem (Instagram)

| Dia | Peça |
|---|---|
| D-14 | Carrossel "Termos de uso" no feed |
| D-10 | Reel "Circadiano" / "Sem IA" |
| D-7 | Reel "Disclaimer" |
| D-3 | Reel "Nossos dados" / "Notificações" |
| D (lançamento) | Story: "já tá na App Store. ou não. tanto faz." |

### Orçamento Instagram (US$ 100)

US$ 10 de boost por Reel pra testar (3 x $10 = $30).
US$ 70 reserva pro que performar melhor.
Se nenhum performar, itera o criativo antes de gastar.

---

## Canal 2: App Store

### Título & Subtítulo

**Título:** feedmine — Leitor de RSS
**Subtítulo:** Construído com IA. Decidido por humanos.

### Descrição

```
O feedmine é um leitor de RSS. Só isso.

O feed é infinito enquanto alguém, em algum lugar, publicar
algo. As cores mudam com a hora do dia — 5 momentos, 5 paletas.
Chama "circadian engine" porque "switch case" não soa bem.

97 países. Curadoria manual. Fofoca global.

Seus dados: um arquivo JSON. No seu telefone. Se desinstalar,
foi junto. Não temos servidor. Não temos nuvem. Não temos
pra onde mandar.

Sem algoritmo de recomendação. Sem "trending now". Sem
"escolhido para você". Você escolhe o que ler. Sozinho.

Sem notificação. Sem cadastro. Sem email. Sem senha.

Sem anúncio. Sem assinatura. Sem "pro" escondido.
Gratuito. Fim.

—

O que o feedmine NÃO faz:
• Te prender
• Te conhecer
• Te recomendar
• Te notificar
• Te cobrar

O que o feedmine faz:
• Mostra o que suas fontes publicaram
• Muda de cor sozinho
• Calcula a fase da lua (não pergunte pra quê)

—

Feito em SwiftUI. iOS 18+.
```

### Keywords (100 caracteres)

```
rss,leitor,feed,noticias,sem,anuncio,sem,ia,privado,circadiano,gratis,json,offline
```

### Screenshots (6 imagens)

| # | Imagem | Texto no screenshot |
|---|---|---|
| 1 | Feed principal, manhã, warm earth | "Feito por humanos. Zero servidores." |
| 2 | Mesmo feed, período noturno | "7h e 23h. Mesmo app. Cores diferentes." |
| 3 | Seletor de países/regiões | "97 países. Fofoca global." |
| 4 | Article reader com artigo aberto | "Sem algoritmo entre você e as palavras." |
| 5 | Filtro de humor/categoria | "Filtro de humor: procura 'crisis' no título. Zero IA." |
| 6 | Feed no fim (seções esgotadas) | "Acabou. Vai viver. Ou adiciona mais fonte." |

### Nota sobre humor na App Store

O humor na descrição da App Store pode ser auto-depreciativo sobre o que foi **escolhido não fazer**, mas nunca sobre o app ser **defeituoso**. "Esquecemos da backdoor" e "contém falhas" não entram na Store — ficam só no Instagram. O tom da Store é irônico mas não sugere bugs ou problemas de segurança.

---

## Canal 3: Reddit — Voz do Wagner

### r/nosurf

```
I was clinically addicted to scrolling. Like, if you measured it
like cigarettes or gambling, I'd qualify. And I use Instagram way
less than my wife and some of my friends.

Let that sink in.

Here's what I noticed: it's not the content. I could be scrolling
through jokes — literally just jokes — and I'd still leave the feed
exhausted. Drained. Like I'd been somewhere I didn't want to be.

The content isn't the problem. The chaining is.

Every social feed works like a casino doorman. "Leaving already?
Look at this. And this. And this." It's not designed for you to
finish. It's designed for you to forget you were about to leave.

And I remember when it wasn't like this.

I remember Google Reader. I remember chronological Twitter — when
it was just people I chose, in order, and it ended. I even remember
Netscape directories — curated, sure, someone else decided what was
there. But it was STATIC. It wasn't trying to hold me. It was just
a list.

I also realized I miss reading a newspaper. Not the paper itself.
Not even the news. I miss the ROUTINE. Opening something reasonably
predictable, reading it, finishing it. That rhythm. The feed has no
rhythm. It has no end. It has no respect for your time.

So I went back to RSS. But the RSS readers I found were either too
heavy, or had their own algorithmic curation, or just felt like
clicking links on a blog in 2006. And honestly — I don't have the
patience for that anymore. I wanted the substance of RSS with the
UX of social media.

So I built it.

It's an RSS reader called feedmine. It looks and feels like a social
feed — infinite scroll, cards, images, swipe gestures. But underneath:

— No algorithm. Round-robin from your sources. You picked them.
— No content generation. When your sources stop publishing, the
  feed stops. Like a newspaper. You finish it.
— No server. Your data stays on your phone. I didn't build a backend.
— No notifications. No "you haven't read in 3 days." No casino doorman.

It has feeds from 97 countries because I wanted to read outside
my bubble. It changes colors with the time of day because I thought
it would feel nicer at 11pm vs 7am. And it's free — no ads, no
subscription, no account.

This isn't a startup. I built it for myself. If it helps other
people break the scroll cycle too, that's even better.

iOS 18+. Link in comments.

Curious what you think. Especially if you also remember when the
internet felt less like a trap.
```

### r/digitalminimalism

```
The casino doorman in your pocket

If you measured my Instagram usage like an addiction — the way we
measure cigarettes or gambling — I'd be clinically addicted. And I
use it less than my wife. Way less than some of my friends.

That's the baseline we're working with here.

Here's what took me way too long to figure out: the content isn't
the problem. I could scroll through nothing but jokes for an hour
and leave feeling drained. Not because the jokes were bad. Because
every social feed has a casino doorman built in. "Leaving already?
Look at this. Wait — this too."

It's not about what you're seeing. It's about the feed never letting
go.

I started remembering when the internet didn't feel like a trap.
Google Reader. Chronological Twitter — just people I chose, in order,
and then it ENDED. Even Netscape directories — someone else's
curation, sure, but static. A list. It wasn't trying to hold me
there.

I also realized what I actually miss about newspapers. Not the paper.
Not even the journalism. The ROUTINE. Opening something predictable,
reading it, and being done. The rhythm of it. Social media has no
rhythm. It has no respect for the fact that you have a life outside
of it.

So I went looking for RSS readers. The ones I found either felt like
2006 (click a link, read a blog post, click back, repeat) or had
their own algorithmic curation. Which defeats the whole point.

I ended up building my own. It's called feedmine.

The idea is simple: the substance of RSS, the UX of social media.

You scroll through cards. You swipe to read or bookmark. It feels
familiar. But under the hood:

— No algorithm. Round-robin from YOUR sources. You chose them.
— No endless feed. When your sources stop publishing, it stops.
  Like a newspaper. You finish it.
— No server. Your data is a JSON file on your phone. I didn't build
  a backend. (I have literally nowhere to send anything. That's not
  a privacy philosophy — it's just... I didn't build it.)
— No notifications. No "come back." No casino doorman.
— No account. No email. No password.

It does track some context — reading pace, streak, whether you opened
at your usual hour. Even the moon phase. But it's all on-device.
UserDefaults and a JSON file. I can't see any of it. There's nowhere
for it to go.

I'm not saying this is the solution to digital addiction. It's just
a tool that doesn't fight against you. And honestly? That's rare now.

Free. No ads. iOS.

Link in comments. If you try it, tell me what's broken. If it's not
for you, that's useful too.
```

### r/apple (opcional, se houver tempo)

```
Your iPhone adjusts color temperature by time of day. My app adjusts everything.

iOS has True Tone and Night Shift. They adjust your screen's color
temperature based on ambient light and time.

But every app on your screen stays exactly the same at 7am and 11pm.

So I built an RSS reader with a circadian design system. 5 time periods,
5 color palettes. The accent color, font weight, letter spacing, line
height, card padding — all drift based on the hour. Over a 2-second
animation. You don't configure this. It just happens.

It's the most unnecessary feature I've ever built. An enum with 5 cases.
Calling it "circadian engine" because "switch statement" doesn't sound
as good in the App Store.

The app is free. No ads. No accounts. No servers — state is a JSON file
on your phone.

I built it because I wanted to read RSS without the friction of 2006-era
readers. Cards. Swipe. Like social media UX, but with your own sources.

Link in comments.
```

---

## Canal 4: Hacker News — Voz do Wagner

### Show HN

```
Show HN: Feedmine – RSS reader that feels like social media, works like a newspaper

I was clinically addicted to Instagram. Not figuratively — if you
applied the diagnostic criteria we use for gambling or cigarettes,
I'd qualify. And I use it less than most people I know.

It's not the content. I could scroll jokes all day and feel drained.
The damage is the chaining — every feed is a casino doorman:
"leaving? one more. one more. one more." You show up for the jokes
and leave exhausted. Not because of what you saw. Because of how it
was served.

I remembered Google Reader. Chronological Twitter. Even Netscape
directories — static curation, someone else's choices, but FINITE.
A list. You opened it, you read it, you closed it.

I missed the routine of a newspaper too. Not the paper. The RHYTHM.
Open something predictable. Read. Be done.

RSS is the answer. But most readers feel like 2006 — click link, read,
click back, repeat. I don't have the patience anymore. I wanted RSS
substance with social media UX. Cards. Swipe. No friction.

So I built it. feedmine. iOS.

What's under the hood:

// No backend
State is feedmine_state.json. Documents folder. zlib. Backup rotation.
Schema v1→v2→v3. All on-device. I didn't build a server. I have
nowhere to send your data. Privacy as a side effect of laziness.

// No algorithm
Round-robin interleave + dedup. Mood filter: title.contains("crisis")
→ serious. title.contains("wow") → fun. 15 keywords. Switch statement.

// Search scoring
exactTitle=100, prefix=80, titleContains=60, excerptContains=30,
else=10. Zero embeddings. String.contains() and a scoring function.

// Circadian design
5 time periods. Colors, typography, spacing shift by hour. Enum with 5
cases. 2-second animation on hour change. "Circadian engine" sounds
better than "switch statement" in the App Store.

// Session tracking
30-second Timer → increments an int in UserDefaults. Reading pace =
articlesRead / sessionMinutes. Streak = did you open yesterday? All
on-device. No analytics SDK. No third-party anything.

// Moon phase
Julian date math. 15 lines. No purpose. It just makes me happy.

// Content
97 countries. ~2,000 RSS feeds curated manually. Python CLI to verify
links and clean dead ones. The OPMLs ship with the app.

The thing I care about: when the feed ends, it ends. No content
generation. No "trending." No "you might like." You read what your
sources published. Then you're done.

For engagement metrics: disaster. For a human: correct behavior.

Free. No ads. No accounts. iOS 18+, SwiftUI 6, strict concurrency.

App Store: [link]

Feedback appreciated. Especially on the interleave algorithm and
whether a local-JSON approach to persistence is insane or fine.
```

---

## Canal 5: Product Hunt — Voz do Wagner

### Maker comment

```
Hey! Wagner here.

I built feedmine because I was addicted to scrolling. Like, if
Instagram usage were measured like cigarettes, I'd qualify. And
I use it way less than my wife. Way less than most of my friends.
Let that be the baseline.

The weird thing: the content wasn't the issue. I could scroll jokes
for an hour — literally just jokes — and leave exhausted. The problem
is how the feed chains things together. Every social app has a casino
doorman: "leaving already? one more. one more." It's designed so you
forget you were about to leave.

I started remembering when the internet wasn't like this. Google
Reader. Chronological Twitter. Netscape directories — someone else
picked what was there, sure, but it was a FINITE LIST. You'd open it,
browse, close it. It wasn't fighting you.

I also realized I miss the ROUTINE of reading a newspaper. Not the
paper. Not even the news. The RHYTHM. Something predictable arrives,
you go through it, you're done.

RSS is the obvious answer. But the readers I found either looked like
2006 — click, read, back, repeat — or had their own algorithms. Which
is just trading one casino for another.

So I built what I wanted: RSS substance, social media UX. Cards.
Swipe gestures. Infinite scroll. But:

— No algorithm. Round-robin from your sources. You chose them.
— No server. Your data lives in a JSON file on your phone. I didn't
  build a backend. I have nowhere to send anything.
— No notifications. Can't — no server. (I tried to find a workaround.
  There isn't one. That's the feature.)
— No content generation. When your sources stop publishing, the feed
  stops. Like a newspaper. You finish it.
— No account. No email. No password. I don't want to manage users.

The app tracks context — reading pace, streaks, whether you're a
morning reader or a night owl. Even the moon phase. But it's all
on-device. UserDefaults. JSON. I literally cannot see it.

It has feeds from 97 countries. I wanted to read news from everywhere.
Curated manually. Took forever.

It changes colors with the time of day. Dawn feels different from 11pm.
That's just because I thought it would be nice. And it is.

Free. No ads. No catch. I built this for myself. If it helps someone
else break the scroll cycle, even better.

I'd love honest feedback — especially what's broken, confusing, or
missing. "This sucks" is more useful than "great app" if you tell me why.

Thanks for reading.
```

### Tagline PH

"RSS substance, social media UX. No algorithm. No server. No casino doorman."

---

## Canal 6: Email para jornalistas / podcasts — Voz do Wagner

```
Subject: an RSS reader, a casino doorman, and Google Reader nostalgia

Hi [Name],

I've been following your work for a bit. This isn't a pitch — it's
more that I built something and I think you'd find the thinking
behind it interesting, even if the app itself isn't for you.

I was clinically addicted to Instagram. Not being dramatic — if you
measured it like gambling or cigarettes, I'd qualify. And I use it
less than my wife. Less than most of my friends.

Here's what I realized: the content isn't the problem. I could scroll
through nothing but jokes all day and leave exhausted. The problem is
the chaining. Every social app has a casino doorman. "Leaving already?
Wait, one more." You show up for jokes and leave drained — not because
of what you saw, but how it was served.

I started remembering Google Reader. Chronological Twitter. Even
Netscape directories — static curation, but FINITE. A list. You'd
open it, read it, close it. It wasn't fighting you.

I also realized I miss the routine of newspapers. Not the paper. Not
the journalism. The RHYTHM. Something predictable. Read it. Done.

RSS is the answer, but the readers I found either felt like 2006 —
click, read, click back — or had their own algorithmic curation. At
that point it's just trading one casino for another.

So I built feedmine. RSS substance, social media UX. Cards, swipe,
no friction. But:

— No algorithm. Your sources, chronological, round-robin.
— No server. Data stays in a JSON file on your phone.
— No notifications. Literally can't — no backend.
— No content generation. Feed ends when you're caught up.
— No account. No ads. Free.

Feeds from 97 countries. Changes colors with the time of day.
Built for myself. iOS.

I'm not looking for coverage. I'm looking for someone who sees the
same problem and might have thoughts — even if the thought is "this
approach doesn't work and here's why."

Link: [App Store]

Thanks for reading.

Best,
Wagner
```

---

## Mastodon / X — Micro-conteúdo

Posts avulsos pra presença contínua:

- "Meu app não tem notificação. Não é filosofia. É que não tem servidor."
- "Todo app quer que você fique mais. O feedmine quer que você leia e saia. Péssimo pra métrica. Ótimo pra você."
- "Adicionei feeds de 97 países. Não por estratégia de crescimento. Porque eu queria ler jornal do Senegal."
- "O feedmine não tem 'engajamento'. Tem leitura. São coisas diferentes."
- "Seus dados: um JSON. No seu telefone. Se você desinstalar, some. Isso é uma falha de negócio. Mas é uma feature de privacidade."
- "O feedmine respeita o seu tempo. Quando o conteúdo acaba, acaba. A gente não vai gerar mais."

---

## Press Kit

1-pager em PDF + pasta no Google Drive:

- Nome: feedmine
- One-liner: "RSS substance, social media UX. No algorithm. No server. No casino doorman."
- Descrição curta (100 palavras): feedmine is an RSS reader for iOS built by Wagner Montes. It combines the substance of RSS with the UX of social media — cards, swipe gestures, infinite scroll. But underneath: no algorithm (round-robin interleave), no server (JSON on device), no notifications, no ads, no accounts. 97 countries of curated feeds. Circadian design system that changes colors with the time of day. Free. iOS 18+.
- 5 screenshots (iPhone 16 Pro, light + dark)
- GIF da transição circadiana
- Logo + wordmark (PNG + SVG)
- Ficha técnica: iOS 18+, 40 línguas, 97 países, gratuito
- Contato: Wagner Montes, wmontes@gmail.com
- App Store link

---

## Timeline

```
SEMANA 1 (8-14 Jul)     SEMANA 2 (15-21 Jul)    SEMANA 3 (22-28 Jul)
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────┐
│ PRÉ-LANÇAMENTO  │    │ PRÉ-LANÇAMENTO  │    │ 🚀 LANÇAMENTO       │
│                 │    │                 │    │                     │
│ • Perfil IG     │    │ • Reels no IG   │    │ • App Store publish │
│ • 9 posts grade │    │ • Press kit     │    │ • PH launch day     │
│ • Carrossel IG  │    │ • Contatos PR   │    │ • HN Show HN        │
│ • Reddit drafts │    │ • Pitch emails  │    │ • Reddit posts      │
│ • HN draft      │    │ • Mastodon      │    │ • Press pitches     │
│ • ASO App Store │    │ • App Store     │    │ • Boost Reels       │
│ • Screenshots   │    │   submission    │    │ • Community engage  │
└─────────────────┘    └─────────────────┘    └─────────────────────┘
```

### Dia D (lançamento)

| Hora (PT) | Ação |
|---|---|
| 6am | Post r/nosurf |
| 8am | Show HN |
| 10am | Product Hunt launch |
| 12pm | Post r/digitalminimalism |
| 2pm | Post r/apple (opcional) |
| 4pm | Mastodon + X |
| 6pm | Responder todos os comentários |

### Pós-lançamento (dias 2-7)

Todo dia, 30 min: responder reviews na App Store, engajar posts Reddit/HN, verificar métricas.

---

## Orçamento (US$ 100)

| Item | Valor |
|---|---|
| Boost Reels (teste: 3 x $10) | $30 |
| Reserva (Reel vencedor ou micro-influenciador) | $70 |
| **Total** | **$100** |

---

## O que NÃO fazer

- ❌ "Baixe agora!" / "Best RSS reader!" / qualquer frase que trate o usuário como idiota
- ❌ Gastar $100 de uma vez sem testar criativo
- ❌ Postar em 5 subreddits no mesmo dia
- ❌ Email genérico pra 50 jornalistas
- ❌ Pedir review na App Store com popup
- ❌ Mencionar Claude Code / IA nos textos sérios (nichos, email, PH)
- ❌ Inventar piada sem lastro real no código
- ❌ Ser didático nas peças de Instagram (explicar a piada)

---

## Métricas de sucesso

| Métrica | Mês 1 |
|---|---|
| Downloads | 500-5.000 |
| Reddit: upvotes totais | 500+ |
| HN: front page? | Sim/Não |
| PH: posição do dia | Top 10 |
| Instagram: Reel mais visto | 5.000+ views |
| Reviews na App Store | 20+, 4.5+ estrelas |
| Menção em imprensa | 2+ artigos |
