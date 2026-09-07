# Omashiki to-be

Isto foi escrito como o produto que eu percebi que tu queres, **antes** de
existir código. Serve para confirmares ou corrigeres. Se uma frase estiver
errada, o resto pode estar errado com ela.

Não há código aqui. Há pessoas, casas, máquinas, um trabalho, e sistemas à porta da casa.

**Estado (2026-09-06).** As seis fases de
[omashiki-to-be-implementation.md](omashiki-to-be-implementation.md) estão
merged em `master`. A checklist no fim diz, item a item, o que o código já
sustenta e o que ainda é promessa. Duas lacunas conhecidas: o broker da
identity só foi provado contra um GitHub simulado, e só o harness opencode
recebe a configuração MCP que lhe apresenta a identity.

---

## A imagem em uma frase

Tu possuis máquinas. Cada developer tem a **sua** casa Omashiki. As
máquinas não pertencem a nenhum developer. Trabalho de qualquer casa pode
correr em qualquer máquina livre. A máquina não sabe quem é a pessoa. Só
sabe que **este trabalho** veio **desta casa**.

---

## Quem é quem

Há cinco papéis. Se misturarmos dois, o desenho parte.

**Tu (operador da frota).**
Compras e ligas os VPS. És tu que decides quais máquinas existem e quais
casas podem mandar trabalho para elas. Os developers não ligam máquinas.
Não recebem a chave da máquina.

**O developer.**
Uma pessoa que quer mandar trabalho: “faz isto neste repositório, neste
ambiente”. Autentica-se **na casa dela**, nunca na máquina. Vê só os
trabalhos dela. Não vê a frota como um computador em que entra.

**A casa (o manager).**
Há **uma casa por developer**. A casa é o Omashiki dessa pessoa: o sítio
onde ela entra, a fila dela, os repositórios que ela declarou, as chaves
do modelo dela, o histórico, o resultado. Duas casas nunca partilham a
mesma fila nem os mesmos dados. João não lê a casa da Ana.

**A máquina (o worker, o nó).**
Um VPS com capacidade: quantos trabalhos pode correr ao mesmo tempo. Não
é uma conta. Não é um utilizador. Não escolhe developer. Está alheia a
qual casa lhe mandou o trabalho. Quando está livre, pega o próximo
trabalho de alguma casa que tu deixaste falar com ela. Quando acaba,
devolve o resultado **só** a essa casa e fica livre outra vez.

**O trabalho (o job).**
A única coisa que a máquina executa. Não é “a Ana”. Não é “o manager”.
É um pedido já aceite pela casa: o que fazer, onde, até quando, para
onde vai o resultado. A autenticação que a máquina precisa, precisa
**neste** trabalho, e quem a apresenta é a casa — não o developer em
pessoa.

**O sistema (GitHub, Jira, o handler).**
Uma porta à frente da casa. Ouve o mundo — uma issue etiquetada, um ticket — e traduz isso num trabalho. Não é a Ana. Não é a máquina. Não entra no VPS. Autentica-se **na casa**, como qualquer cliente que manda trabalho.

Há duas faces do GitHub App, e não se confundem:

- **App como cliente à porta** — o handler recebe o webhook, verifica o segredo, traduz issue → trabalho. Quem *enviou* o pedido.
- **App como identidade do agente** — declarada no TOML da casa, no agente (`[identities.*]`). É quem o agente **é** quando comenta, etiqueta ou abre PR.

A casa conhece o cliente à porta: pode mandar trabalho e receber o resultado. O agente, quando actua no GitHub, usa a identidade declarada na casa — não o handler.

---

## O que nunca acontece

Se isto acontecer, não é o produto:

- Um developer a entrar num VPS, por SSH ou por um login no nó.
- Uma máquina com utilizadores (“conta da Ana neste worker”).
- Uma só casa Omashiki partilhada por todos os teus devs, com a frota
  atrás — isso é outra coisa (uma empresa, uma fila comum).
- A máquina a guardar a password da Ana, a chave do modelo dela, ou a
  lista dos trabalhos dela.
- A máquina a devolver o resultado da Ana para a casa do João.
- O agente, dentro da sandbox, a poder empurrar sozinho para o Git remoto
  canónico.
- Um GitHub App a autenticar-se no nó, ou a viver como utilizador da máquina.
- A chave privada da App, o segredo do GitHub, ou o token de instalação a irem no trabalho, na sandbox, ou para o VPS.
- O webhook do GitHub a chegar à máquina. Inbound é casa, ou o sistema à frente da casa.
- A pasta `~/.claude` da Ana montada no VPS.
- `host_credentials` no `worker.toml`.
- Um `include` em cadeia, ou um segundo ficheiro a “ganhar” o mesmo nome.
- Path relativo solto (`./` ou `../`) como origem de credencial.
- Uma App da organização a despejar issues na casa da Ana **e** na do João. O sistema é cliente **de uma casa**. App da Ana → casa da Ana. App da empresa → casa da empresa — e isso já é o produto “uma fila, muitos logins”, não “um Omashiki por developer”.

---

## Passo a passo: tu levantas capacidade

1. Alugas VPS. Cada um é só ferro e um sítio para correr sandboxes.
2. Pões nesses VPS o papel de **máquina Omashiki** — não a casa de
   ninguém. Sem fila de pessoas. Sem ecrã de developer. Sem dados da
   Ana ou do João.
3. Ligaste a máquina à frota: ela agora pode **receber** trabalho. Isso
   é confiança na **máquina** (“este VPS é meu / desta frota”), não um
   login de pessoa.
4. A máquina tem um tecto: por exemplo quatro trabalhos ao mesmo tempo.
   Esse tecto é da **máquina**, não “quatro para a Ana e quatro para o
   João”. Se Ana e João mandarem trabalho ao mesmo tempo, partilham esses
   quatro sítios. A máquina não duplica a capacidade por casa.

Neste ponto ainda ninguém mandou trabalho. Só existe ferro honesto.

---

## Passo a passo: um developer passa a poder usar a frota

1. Esse developer ganha a **casa dele**. Casa própria: entrada própria,
   trabalhos próprios, chaves dele, repositórios que ele declarou.
2. Tu (não ele) deixas a casa dele falar com as máquinas da frota. Ele
   não recebe a chave das máquinas. Não “enrola” VPS. Não escolhe o
   hostname do worker.
3. A partir daí, o dia dele é: abrir **a casa dele** e mandar trabalho.
   Do ponto de vista dele, Omashiki é a casa. A frota é invisível, ou
   aparece só como “há capacidade / não há”.
4. Se o quiseres tirar da frota, cortas a casa das máquinas. Os VPS
   continuam. Os outros developers continuam. A casa dele deixa de
   conseguir colocar trabalho nas tuas máquinas.

Ele nunca “autentica no worker”. Autentica na casa. A casa é que, **por
ele**, apresenta cada trabalho à máquina.

---

## Passo a passo: um dia de trabalho da Ana

1. A Ana abre a casa dela e entra. Isto é ela a provar quem é **à casa**.
   Nenhuma máquina está envolvida.
2. Manda um trabalho: a instrução, o repositório que a casa já conhece, o
   ambiente que a casa já conhece. Não manda chaves. Não manda “corre no
   VPS 3”. Não aponta a um worker.
3. A casa aceita o trabalho como **dela**. Fica na fila dela. O João não
   o vê. A máquina ainda não sabe que o trabalho existe.
4. Alguma máquina livre da frota pergunta às casas que pode servir:
   “tenho sítio, há trabalho?”. Pode ser a casa da Ana, ou a do João, ou
   a de outro. A máquina **não escolhe pessoa**. Pega um trabalho de
   quem tiver fila e sítio.
5. A casa da Ana oferece **este** trabalho a essa máquina: o retrato
   fechado do que foi aceite (o que correr, o repositório, o ambiente, o
   sítio do resultado). A máquina autentica a **casa** — “és uma casa
   que eu posso servir” — e aceita **este** trabalho. Não pede a
   password da Ana. Não revalida o login dela. A autenticação da pessoa
   já aconteceu na casa; no worker, a unidade é o job.
6. A máquina abre uma sandbox descartável só para esse trabalho. O agente
   trabalha lá dentro. Acabou o trabalho, a sandbox some.
7. Se o agente precisa de um modelo, não leva a chave da Ana na sandbox
   e não fala com o fornecedor “em nome da máquina”. Pede à **casa da
   Ana**. A chave do modelo vive na casa. A máquina é só o sítio onde o
   pedido acontece.
8. Se o resultado é uma branch: o agente pode escrever e fazer commit
   **dentro** da sandbox. Não pode empurrar para o remoto canónico. Quem
   publica, **depois** das regras da casa (tamanho, segredos, caminhos
   protegidos), é a máquina — já fora da sandbox — para o remoto **deste**
   trabalho. Depois diz à casa da Ana: aqui está a branch, estes são os
   commits. A casa é que guarda o resultado e avisa a Ana.
9. A Ana vê o resultado na casa dela. O VPS já não tem o trabalho. O
   próximo trabalho nesse VPS pode ser do João. As duas sandboxes nunca
   se vêm.

O mesmo passo a passo vale para o João, na casa do João, no mesmo VPS,
noutro momento ou ao mesmo tempo noutro sítio da máquina.

---

## Passo a passo: uma issue chega à casa da Ana

A camada fina que já consegues fazer **é** a integração. O handler ouve o GitHub e fala com **a casa**; o VPS nunca vê o webhook.

|Quem|O que é no GitHub|O que é no Omashiki|
|---|---|---|
|**A casa da Ana**|o sítio que aceita o trabalho e guarda o resultado|a casa dela|
|**O GitHub App**|o sistema que ouve a issue e comenta no fim|um cliente de trabalho da casa|
|**A máquina**|nada|corre o job; não sabe que existe GitHub|

O App **não** é um utilizador do worker. **Não** autentica no nó. Autentica na casa, **por aquele trabalho**, exactamente como no resto desta visão.

1. Alguém etiqueta a issue. O GitHub chama o **App**. Isto ainda não é Omashiki. A prova é do GitHub para o sistema (a App, a instalação).
2. O sistema verifica o GitHub, decide “isto é trabalho”, e manda à **casa da Ana**: a instrução (“faz a triagem”) e o contexto (número, título, corpo, labels). Sem chaves. Sem “corre no VPS 3”. Sem escolher o agente, o modelo, ou o sítio onde corre.
3. A casa admite o trabalho **como dela**, em nome deste cliente. O João não o vê. A máquina ainda não sabe que o trabalho existe.
4. Uma máquina livre pega o trabalho, corre a sandbox, devolve o resultado **só** à casa da Ana. Não comenta na issue. Não fala com o GitHub.
5. A casa avisa o sistema: o trabalho acabou. O sistema é que comenta ou etiqueta a issue. O VPS já não tem o trabalho.

O **cliente** à porta (handler) traduz a issue e POSTa o trabalho. A **identidade** do agente no GitHub — quem comenta ou etiqueta no fim — vive no TOML da casa (`[identities.*]`), não no handler.

O mesmo vale para Jira, Azure DevOps, ServiceNow. O sistema muda. A fronteira não: duas setas — o trabalho a entrar na casa, o resultado a sair para o sistema.

---

## Como se adiciona a identidade de um GitHub App

O agente da casa tem uma cara. Essa cara pode ser um GitHub App. Se declara **na casa**, **no agente**, ao lado das outras identidades que o agente já tem (quem paga o modelo, quem é o harness). Não é uma tabela de issues. Não é um tipo de trabalho. Não é um campo no trabalho.

```toml
[identities.ana-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:ANA_GITHUB_APP_PRIVATE_KEY}"

[presets.reviewer]
plugin = "jcode"
identities = ["ana-bot"]

[environments.review]
preset = "reviewer"
runtime = "docker.runc.debian"
sink = "git"
credentials = ["llm"]
executables = ["git"]
```

`kind = "github-app"` é quem este agente **é** quando actua (comentar, etiquetar, abrir PR) — o mesmo sítio das outras identidades, não uma integração com tracker.

As chaves desse tipo são `app_id`, `installation_id`, `private_key` (só `${env:VAR}`); sem eventos, sem filtros de issue, sem segredo de webhook — isso fica no handler.

`identities` pendura no **preset** (o agente); o ambiente só escolhe o agente.

A chave privada fica na casa: a sandbox nunca a recebe, a máquina nunca recebe uma cópia desta tabela.

O handler à porta continua a ser um cliente (quem enviou o trabalho); esta identidade é quem o agente é enquanto o trabalho corre.


## Duas formas, uma fronteira

**A — Só o handler (triagem fina).**
O App à porta só manda trabalho e recebe o fim. A issue I/O fica no handler. O agente pode não precisar de identidade GitHub — ou pode ter uma na casa se, noutro fluxo, precisar de actuar no repositório. Zero GitHub no trabalho, na sandbox, ou na máquina.

**B — O agente usa a cara GitHub.**
O agente veste `ana-bot` (`[identities.*]` no preset). A sandbox pede à casa; a casa age **como** esse App em nome do agente. O MCP pode ser genérico — é o tubo. O **nome** da identidade é `[identities.ana-bot]`, não um campo no trabalho.

Não mistures B com “deixar a conta GitHub da Ana no disco do VPS”. Isso era dar a frota a conta dela.

---

## Hierarquia da casa (o TOML)

O grafo do produto, independente de um ficheiro ou vários:

```
plugin        → como a ferramenta corre
identity      → quem o agente é (ex.: GitHub App)
preset        → o agente (plugin + identities)
environment   → a caixa (runtime, rede, credenciais, MCP)
repository    → o git
```

As setas:

- `environment.preset` → exactamente um preset
- `preset.plugin` → um plugin (os ficheiros `plugins/*.toml` já existem; cada um é um plugin)
- `preset.identities` → zero ou mais identidades (reutilizáveis)
- `environment.credentials` → nomes em `credentials` / `host_credentials`
- O `environment` **não** aponta para `identity`. A cara está no agente, não na caixa.
- MCP de Jira/tracker é `url` + `headers` no environment, não é identity. Identity é quem o agente é (GitHub App). MCP é um tubo.

O ficheiro da máquina (`worker.toml`) é outra árvore: só `limits` + `docker`. Sem identidades, sem credenciais, sem `include` da casa.

---

## Um ficheiro ou vários

Hoje a casa é um `omashiki.toml`. No to-be: o mesmo produto, com divisão opcional.

O monólito continua válido. O `include` é opcional.

O `include` só na raiz. Os pedaços não incluem pedaços. Profundidade 1. Caminhos dentro da pasta da casa. União: o mesmo nome em dois sítios falha o boot (sem overlay — ninguém “ganha”). O digest é do snapshot unido; partir o mesmo conteúdo não muda o digest.

A raiz guarda sempre (o boot lê este ficheiro antes do core): `[app]`, `[db]`, `[auth]`, `[reload]`, `[runtimes]`, `[limits]`, `[nodes]` e a própria lista `include`.

Divisível: `identities`, `presets`, `environments`, `credentials`, `host_credentials`, `repositories`, `caches`.

O `include` pode nomear um ficheiro ou uma pasta (carrega `*.toml`, nome = basename) — o mesmo padrão que `plugins/*.toml`.

Exemplo curto: raiz com `include`, um ficheiro de identity, um de preset. Dois presets podem listar o mesmo `ana-bot`. Um perfil de agente **não** é um saco que engole a identity — senão não reutilizas a cara.

```toml
# omashiki.toml (raiz)
include = ["identities/ana-bot.toml", "presets/reviewer.toml"]

[app]
# [db] [auth] [reload] [runtimes] [limits] [nodes] — infra na raiz
```

```toml
# identities/ana-bot.toml
[identities.ana-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:ANA_GITHUB_APP_PRIVATE_KEY}"
```

```toml
# presets/reviewer.toml
[presets.reviewer]
plugin = "jcode"
identities = ["ana-bot"]
```

Recusa:

- identity dentro de `environment` ou do payload do trabalho
- identity no `worker.toml`
- merge com override
- `include` em cadeia / URLs / caminhos fora da casa
- tabela `[github]`

Numa frase: o truque actual do loadtest (`cat fragment >> omashiki.toml`) passa a ser um `include`.

---

## Quem escolhe o environment

Quem submete o trabalho escolhe o **nome** do environment. Já é assim hoje (`POST /api/v1/jobs`, campo `environment`).

A casa **declara** o que esse nome significa (preset, runtime, credenciais, identidades). O cliente — a Ana na UI, o handler, outro agente — só escolhe entre nomes que existem. Não inventa a caixa. Não manda modelo, plugin, ou GitHub no payload (só instrução + contexto).

A máquina não escolhe. O trabalho chega com o environment capturado na admissão.

---

## Três casas (o mesmo produto, três tamanhos)

Três exemplos concretos. A infra `[app]`/`[db]`/`[auth]`/`[reload]`/`[runtimes]`/`[limits]` aparece completa só na primeira; nas outras, “o resto da infra igual”. O `worker.toml` é sempre o mesmo — não é uma quarta casa.

### 1. Simples — um ficheiro, zero include

João, só UI. Um repo, um modelo, um agente. Sem GitHub, sem Jira. Sem `[identities]`. João é a pessoa da casa; o agente não tem cara GitHub.

```toml
# omashiki.toml
[app]
port = 4010
host = "0.0.0.0"
[db]
port = 5442
[auth]
enabled = false
[reload]
mode = "gradual"
[limits]
max_concurrent_containers = 4
[runtimes.docker.runc.debian.images]
jcode = "omashiki/agent-jcode:latest"

[credentials.llm]
provider = "openai"
model = "gpt-4.1-mini"
base_url = "${env:OMASHIKI_LLM_BASE_URL}"
api_key = "${env:OMASHIKI_LLM_API_KEY}"

[repositories.meu-servico]
remote = "git@github.com:joao/meu-servico.git"
base_branch = "main"
ssh_key = "~/.ssh/omashiki_deploy"
ssh_key_passphrase = "${env:OMASHIKI_GIT_KEY_PASSPHRASE}"

[presets.dev]
plugin = "jcode"

[environments.dev]
preset = "dev"
runtime = "docker.runc.debian"
sink = "git"
credentials = ["llm"]
executables = ["git"]
```

### 2. Multi-provider — ainda um ficheiro

Ana: modelo local barato + fallback OpenRouter. Dois agentes, **a mesma** GitHub App.

```toml
# o resto da infra igual ao 1

[credentials.local]
provider = "openai"
model = "qwen2.5-coder"
base_url = "${env:OMASHIKI_LOCAL_LLM_BASE_URL}"
api_key = "unused"
fallback_chain = ["openrouter"]

[credentials.openrouter]
provider = "openai"
model = "z-ai/glm-5.3-flash"
base_url = "https://openrouter.ai/api/v1"
api_key = "${env:OPENROUTER_API_KEY}"

[identities.ana-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:ANA_GITHUB_APP_PRIVATE_KEY}"

[presets.rapido]
plugin = "jcode"
identities = ["ana-bot"]

[presets.forte]
plugin = "opencode"
identities = ["ana-bot"]

[repositories.meu-servico]
remote = "git@github.com:ana/meu-servico.git"
base_branch = "main"

[environments.barato]
preset = "rapido"
runtime = "docker.runc.debian"
sink = "git"
credentials = ["local"]
executables = ["git"]

[environments.review]
preset = "forte"
runtime = "docker.runc.debian"
sink = "git"
credentials = ["openrouter"]
executables = ["git"]
```

O que reutilizas: `ana-bot` em dois presets. O que não duplicas: a chave da App.

### 3. Heavy — parte em pedaços

```
casa/
  omashiki.toml          # include + [app][db][auth][reload][limits][runtimes]
  identities/
    ana-bot.toml
  credentials/
    llm.toml
    openrouter.toml
  presets/
    reviewer.toml
    triagem.toml
  environments/
    triagem.toml
  repositories/
    meu-repo.toml
```

```toml
# omashiki.toml
include = ["identities/", "credentials/", "presets/", "environments/", "repositories/"]
# [app] [db] [auth] [reload] [limits] [runtimes] — o resto da infra igual à casa 1
```

`identities/ana-bot.toml` — mesmo `github-app` que nas outras casas.
`presets/reviewer.toml` e `presets/triagem.toml` — ambos `identities = ["ana-bot"]`.
`environments/triagem.toml` — `mcp_servers.jira` e `mcp_servers.tracker` só com `url` + `headers`.

Jira e tracker **não** são identities. GitHub App é identity. O segredo do webhook do handler fica fora de todos estes ficheiros.

| | Simples | Multi-provider | Heavy |
|---|---|---|---|
| Ficheiros | 1 | 1 | raiz + pastas |
| Identity | nenhuma | `ana-bot` (1×) | `ana-bot` (1×) |
| Credentials | 1 LLM | `local` + `openrouter` | em ficheiros |
| MCP | — | — | `url`+`headers` no env |
| Máquina | `worker.toml` igual | `worker.toml` igual | `worker.toml` igual |

---

## Duas formas de pagar o modelo (gateway vs subscrição)

Hoje numa máquina, os harnesses de subscrição (`claude-code`, Codex, OpenCode host auth) copiam um ficheiro do host para uma pasta por tentativa e montam `/run/omashiki/state`. O gateway (`jcode`, OpenCode via gateway) mantém a chave na casa; o contentor recebe um token de trabalho.

Num nó distribuído:

**Gateway.** A chave fica na casa. O contentor fala com essa casa. O VPS não tem ficheiro. Se a máquina não chegar à casa, recusa o trabalho. Isto é o passo 7 do dia de trabalho.

**Subscrição.** A origem declara-se no TOML da **casa** como `host_credentials` (`kind` + `path`). **Não** está no `worker.toml`. O VPS não deve guardar o login de pessoa da Ana como “a casa copiada para disco”.

Dois factos que fixámos:

1. Fazer login com `claude-code` no worker e esperar que o `~/` do TOML da casa “funcione sozinho”: **não**, se o path foi expandido na casa ao carregar (`~/` virou `/home/ana/...` congelado no snapshot). O worker copia esse path absoluto congelado no **disco dele**. Mesmo Ubuntu + mesmo path absoluto + login no worker é coincidência, não desenho.

2. To-be: **não** congelar `~/` ao carregar a casa. O TOML guarda a forma declarada. A máquina que materializa (o nó que corre Docker) expande `~/` para o home **desse** processo. O snapshot traz `~/.claude/.credentials.json`. O digest é o mesmo em qualquer nó.

```toml
[host_credentials.claude-local]
kind = "claude-code"
credentials = "~/.claude/.credentials.json"
```

| No TOML | Na máquina que copia |
|---|---|
| `~/...` | home **deste** processo Omashiki |
| `/abs/path` | só esse path — ainda não cruza utilizadores |

Recusa: relativo sem âncora (`./` ou `../`) — o cwd não é identidade. `worker.toml` continua sem credenciais. Ficheiro em falta no sítio expandido → a tentativa falha; não procura noutro sítio.

Isto é o login de harness do **ferro** (o operador fez `claude login` como o utilizador que corre o worker), não a Ana a viajar. O refresh OAuth escreve na cópia por tentativa; não escreve magicamente no `~/.claude` de ninguém a menos que um dia adicionemos write-back — isso ainda não está decidido.

| | Gateway | Subscrição |
|---|---|---|
| Onde vive a chave | casa | ficheiro do host (declarado na casa) |
| No contentor | token de trabalho | cópia montada em `/run/omashiki/state` |
| Permanente no VPS | não | só a cópia do ferro, não o login da Ana |
| Casa inacessível | recusa | recusa (se precisar da casa para o resto) |

Não mistures isto com `private_key` do GitHub App. Essa chave fica na casa; a sandbox nunca a recebe; a máquina nunca recebe a tabela `identities`. Os ficheiros de subscrição são outro slot (`host_credentials` → `/run/omashiki/state`).


## As provas, e porque não são a mesma

Sem isto, “autenticar o nó” e “autenticar o user no nó” misturam-se.
Misturar o App com qualquer uma das três é o mesmo erro.

|Prova|Quem prova|A quem|O que significa|
|---|---|---|---|
|**A máquina é da frota**|o VPS|as casas que tu autorizaste|“posso correr trabalho; não sou um estranho na internet”|
|**Esta pessoa é a Ana**|a Ana|**só** a casa da Ana|“posso mandar e ver os *meus* trabalhos”|
|**Este trabalho é deste job**|a casa da Ana|a máquina, **neste** trabalho|“corre isto; devolve só a mim; fala comigo para o modelo”|
|**Este cliente é o App da Ana**|o sistema (GitHub App)|**só** a casa da Ana|“posso mandar trabalhos de triagem e receber o fim”|

A terceira prova é a que tu descreveste: a autenticação que acontece no
worker acontece **naquele job**. Por isso tem de ser a casa a fazê-la.
A casa é uma por developer. O nó não sabe, e não precisa de saber, que a
Ana existe.

A quarta prova não é a Ana. Não é a máquina. É o sistema à porta da casa. O GitHub prova-se ao App; o App prova-se à casa; a casa prova **o job** à máquina. Ninguém salta um degrau.

---

## O que cada um vê

**A Ana vê.**
A casa dela. Os trabalhos dela. O estado, o resultado, a falha. Que há
(ou não) capacidade. Não vê o hostname do VPS como um sítio em que
entra. Não vê os trabalhos do João.

**Tu vês.**
As máquinas. Se estão vivas. Se estão cheias. Quais casas podem mandar
trabalho. Podes retirar uma máquina ou uma casa sem apagar a outra.

**A máquina vê.**
Trabalhos. Quantos sítios livres tem. Para cada trabalho: o retrato que
a casa mandou, e o endereço **dessa** casa para devolver o resultado e
para a sandbox pedir o modelo. Não vê utilizadores. Não vê outras casas
para além das que lhe dão trabalho. Não mistura o disco, a rede, nem o
resultado da Ana com o do João.

**O sistema vê.**
Os eventos do mundo (a issue). O que mandou à casa. O aviso de fim. Não vê o VPS. Não vê a fila do João. Não guarda a casa.

---

## O que vive onde (sem nomes de implementação)

**Na casa do developer.**
Quem ele é. A fila. O que ele declarou que pode correr. As chaves do
modelo (gateway). O histórico. O resultado publicado. Quem é notificado no fim.
As identidades dos agentes — incluindo o GitHub App de `ana-bot`
(`[identities.*]`, ligado ao preset). A lista `include`. A declaração de
`host_credentials` (`kind` + forma do path, não o ficheiro do ferro).
Os clientes à porta (handler que manda trabalho), e o sítio para os avisar
quando o trabalho acaba.

**Na máquina.**
Capacidade. Docker. O sítio temporário da sandbox. O espelho local do
Git **daquele** trabalho, separado por casa para não misturar. O ficheiro
de subscrição do **ferro** no `~/` expandido **deste** processo, se esse
environment usa subscrição — depois a cópia por tentativa e descarte.
Não é a password da Ana. Não é a chave privada do GitHub App.

**Em lado nenhum da máquina, nunca.**
Password do developer. Chaves de API do modelo (gateway). A base de dados da casa.
Os outros trabalhos da mesma pessoa.
Chave privada do GitHub App, segredo do webhook do GitHub, token de instalação.

**No handler, à frente da casa.**
Segredo do webhook do GitHub. Mapeamento de eventos (“esta issue → este
trabalho”). A App como **cliente** que POSTa trabalho — não a identidade
do agente, não `host_credentials`.

Quando um trabalho precisa de falar com o mundo (modelo, ferramentas,
pacotes), fala com a **casa dona daquele trabalho**, não com um sítio
genérico da frota. Se a máquina não chegar a essa casa, **recusa** o
trabalho. Não o corre “pela casa do lado”.

---

## Várias casas, as mesmas máquinas

Isto é o ponto central, outra vez, em produto:

- Um developer = uma casa.
- Muitas casas podem usar as mesmas máquinas.
- A máquina é alheia a qual casa lhe mandou o trabalho.
- O trabalho nunca é alheio à casa: o resultado, o modelo, a falha, o
  cancelamento voltam **só** ao dono.

Não é “os meus devs partilham um Omashiki e uns VPS”.
É “os meus devs têm cada um o seu Omashiki, e eu empresto-lhes ferro”.

Uma só casa com muitos logins de developers seria um produto diferente:
uma empresa, uma fila, um dono. Tu descreveste o contrário.

---

## O que isto ainda não é (para não misturar desejos)

- **Não** é a Ana escolher “quero o GPU-1”. A casa manda trabalho; a
  frota coloca-o onde houver sítio. Isolar “esta pessoa só nestas
  máquinas” é um produto à frente, se um dia precisares.
- **Não** é a máquina autenticar a Ana. Se o nó pede o user, o desenho
  inverteu-se.
- **Não** é cada VPS ter uma cópia da casa da Ana (a fila, as chaves, os
  dados). Isso era “N cópias da mesma app a olhar para a mesma base”.
- **Não** é o login Claude da Ana a viajar para o VPS.
- **Não** é um perfil-ficheiro que engole a identity (não reutilizas a cara).
- **Não** é o cliente a mandar o modelo ou o plugin no payload.
- **Não** é confundir o cliente à porta com a identidade do agente. O handler POSTa trabalho; `[identities.*]` no TOML da casa é quem o agente é no GitHub.
- **Não** é um App org-wide a servir duas casas. Escolhe o dono da casa primeiro.

---

## Como sei que percebi

Se isto estiver certo, tu deves poder dizer “sim” a todas. Em itálico, o que
o código já sustenta e onde.

1. Eu ligo N VPS uma vez. Os devs não ligam VPS.
   *Hoje: o worker arranca sem casa e recebe casas por enrollment; `mise run e2e:two-houses`.*
2. Cada dev vive na casa dele, não na minha e não no VPS.
   *Hoje: uma base de dados, um registry e um token de worker por manager; o worker não monta `Repo`.*
3. O dev autentica-se na casa. A casa autentica **o job** na máquina.
   *Hoje: token de worker por casa no poll; claims assinados por job no data-plane.*
4. A máquina não tem utilizadores. Não pergunta quem é a pessoa.
   *Hoje: o worker só conhece id + URL + token de cada casa; `worker.toml` não tem credenciais.*
5. O mesmo VPS pode hoje correr a Ana e amanhã o João, sem saber os nomes.
   *Hoje: um job de cada casa em paralelo no mesmo worker, mirrors por id de casa.*
6. A chave do modelo da Ana nunca mora no VPS.
   *Hoje: `api_key` fica no manager; o container fala com o gateway da casa dona.*
7. O resultado da Ana só existe na casa da Ana.
   *Hoje: `Complete` e blobs só para o manager que ofereceu; a outra casa responde 404.*
8. Tirar a Ana da frota não desliga as máquinas nem o João.
   *Hoje: `DELETE /internal/enroll/:id`; kill/restart de uma casa provado no E2E.*
9. A identidade GitHub do agente (`ana-bot`) vive no TOML da casa, não no VPS.
   *Hoje: `[identities.<name>]`, kind `github-app`, chave só `${env:VAR}`.*
10. O trabalho não carrega chave de App; o TOML do worker não tem GitHub.
    *Hoje: a admissão remove `private_key`; o offer leva só nome, kind e ids públicos.*
11. A máquina que corre o trabalho não precisa de saber que a issue veio do GitHub.
    *Hoje: o handler exemplo manda `instruction` + `context` e o nome do environment; nada mais.*
12. O cliente à porta da Ana não despeja trabalho na casa do João — e a identidade do agente de uma casa não serve outra.
    *Hoje: token de API por casa; o broker resolve a identity pelo nome admitido e recusa se a casa viva a mudou.*
13. Posso deixar o `omashiki.toml` num só ficheiro ou parti-lo com `include`; o produto é o mesmo.
    *Hoje: mesmo digest para monólito e split.*
14. `include` só na raiz; o mesmo nome em dois sítios falha o boot.
    *Hoje: `Config.Error` na colisão; profundidade 1; sem sair do diretório da casa.*
15. Quem POSTa o job escolhe o **nome** do environment; não inventa a caixa.
    *Hoje: já era assim.*
16. `~/` nas `host_credentials` expande na máquina que corre o container, não no home da Ana congelado na admissão.
    *Hoje: a forma com `~/` viaja no snapshot; `materialize` expande contra o `HOME` do processo que copia.*
17. Jira/MCP não é identity; GitHub App é.
    *Hoje: `identities.kind` só aceita `github-app`; Jira continua em `mcp_servers` do environment.*

O que ainda **não** foi provado: um comentário num GitHub real (o broker foi
testado contra um GitHub simulado com JWT verificado), e a identity a chegar
aos harnesses Claude e jcode (só o opencode recebe a configuração MCP).

Se algum destes “sim” estiver errado, o documento está errado. Diz qual.