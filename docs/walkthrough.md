# Omashiki — walkthrough

Um passeio pelo produto, funcionalidade a funcionalidade. Não há código
aqui; há pessoas, casas, máquinas, um trabalho e sistemas à porta da casa.
Cada secção diz o que existe, como se usa e onde está a prova. O detalhe
técnico vive em [internal/](internal/README.md).

---

## A imagem em uma frase

Tu possuis máquinas. Cada developer tem a **sua** casa Omashiki. As
máquinas não pertencem a nenhum developer. Trabalho de qualquer casa pode
correr em qualquer máquina livre. A máquina não sabe quem é a pessoa. Só
sabe que **este trabalho** veio **desta casa**.

---

## Quem é quem

Há cinco papéis. Se misturarmos dois, o desenho parte.

**Tu (operador da frota).** Compras e ligas os VPS. Decides quais máquinas
existem e quais casas podem mandar trabalho para elas. Os developers não
ligam máquinas nem recebem a chave delas.

**O developer.** Uma pessoa que quer mandar trabalho: «faz isto neste
repositório, neste ambiente». Autentica-se **na casa dela**, nunca na
máquina. Vê só os trabalhos dela.

**A casa (o manager).** Uma casa por developer. É o Omashiki dessa pessoa:
a entrada, a fila, os repositórios declarados, as chaves do modelo, o
histórico, o resultado. Duas casas nunca partilham fila nem dados.

**A máquina (o worker).** Um VPS com capacidade: quantos trabalhos corre
ao mesmo tempo. Não é uma conta. Não escolhe developer. Quando está livre,
pega o próximo trabalho de alguma casa que tu deixaste falar com ela.
Quando acaba, devolve o resultado **só** a essa casa.

**O trabalho (o job).** A única coisa que a máquina executa. É um pedido
já aceite pela casa: o que fazer, onde, até quando, para onde vai o
resultado. A autenticação que a máquina precisa é **deste** trabalho, e
quem a apresenta é a casa.

**O sistema à porta (GitHub, Jira, um handler).** Ouve o mundo e traduz
isso num trabalho. Não entra no VPS. Autentica-se **na casa**, como
qualquer cliente que manda trabalho.

Um GitHub App tem duas faces que não se confundem: **cliente à porta**
(o handler que recebe o webhook e manda trabalho) e **identidade do
agente** (declarada na casa; é quem o agente é quando comenta, etiqueta
ou abre PR).

---

## A casa: o registry `omashiki.toml`

A casa é um ficheiro TOML. Declara repositórios, presets, environments,
runtimes, credenciais, identidades e limites. O cliente que manda trabalho
escolhe só o **nome** de um environment; a casa é que sabe o que esse nome
significa. O grafo:

```
plugin        → como a ferramenta corre
identity      → quem o agente é (ex.: GitHub App)
preset        → o agente (plugin + identities)
environment   → a caixa (runtime, rede, credenciais, MCP)
repository    → o git
```

`environment.preset` aponta para um preset; `preset.identities` para zero
ou mais identidades; `environment.credentials` para nomes em `credentials`
ou `host_credentials`. O environment **não** aponta para identidades: a
cara está no agente, não na caixa. MCP de Jira ou de outro tracker é
`url` + `headers` no environment, um tubo; identity é quem o agente é.

**Um ficheiro ou vários.** A raiz pode listar `include`:

```toml
# omashiki.toml (raiz)
include = ["identities", "presets/reviewer.toml"]

[app]
# [db] [auth] [reload] [runtimes] [limits] [nodes] ficam sempre na raiz
```

Cada entrada é um ficheiro ou uma pasta de `*.toml` dentro da pasta da
casa. Profundidade um: peças não incluem peças. Só `identities`,
`presets`, `environments`, `credentials`, `host_credentials`,
`repositories` e `caches` podem sair da raiz. O mesmo nome em dois sítios
falha o boot; ninguém «ganha». O digest é do snapshot unido, por isso
partir o ficheiro não muda o que os jobs capturam.

Exemplos em [examples/](../examples/README.md). Prova:
`server/test/omashiki/config/include_test.exs`.

---

## Levantar capacidade: a máquina

1. Alugas um VPS. É só ferro e um sítio para correr sandboxes.
2. Pões-lhe o papel de **máquina** (`OMASHIKI_ROLE=worker`). Sem fila de
   pessoas, sem ecrã de developer, sem dados de ninguém. O ficheiro da
   máquina, [worker.toml](../examples/worker.toml), tem só limites e o
   socket do Docker.
3. A máquina arranca sem casa nenhuma e expõe um listener de enrollment.
   Tu, do teu portátil, enrolas nela cada casa que ela pode servir:

   ```bash
   mise run worker:enroll -- --manager-id ana  --manager-url http://ana.lan:4010  --worker-token $ANA_TOKEN
   mise run worker:enroll -- --manager-id joao --manager-url http://joao.lan:4020 --worker-token $JOAO_TOKEN
   ```

   Enrolar o mesmo id outra vez substitui essa casa. `DELETE
   /internal/enroll/<id>` tira uma casa sem tocar nas outras. `GET
   /internal/enroll` lista ids e URLs, nunca tokens. O que está enrolado
   sobrevive a reinícios.
4. A máquina tem um tecto, por exemplo quatro trabalhos ao mesmo tempo.
   O tecto é da **máquina**, não «quatro para a Ana e quatro para o
   João». As casas partilham esses sítios; a máquina faz round-robin
   entre elas e é ela a autoridade sobre os slots.

Cada casa vê, no seu ecrã inicial, as máquinas que lhe fizeram poll, com
slots livres e um aviso de `stale` quando uma se cala há mais de trinta
segundos. Presença é por casa: uma máquina calada aqui pode estar viva
para outra casa.

Compose pronto a copiar: [compose.worker.yml](../examples/compose.worker.yml)
e [compose.manager.yml](../examples/compose.manager.yml), uma vez por casa.
Prova: `mise run e2e:host-worker`, `mise run e2e:compose-worker`,
`mise run e2e:two-houses`.

---

## Um developer passa a poder usar a frota

1. Esse developer ganha a **casa dele**: entrada própria, trabalhos
   próprios, chaves dele, repositórios que ele declarou.
2. Tu (não ele) enrolas a casa dele nas máquinas. Ele não recebe a chave
   das máquinas nem escolhe o hostname do worker.
3. O dia dele é abrir a casa e mandar trabalho. A frota é invisível, ou
   aparece só como «há capacidade / não há».
4. Para o tirar da frota, cortas a casa das máquinas. Os VPS continuam.
   Os outros developers continuam.

Ele nunca autentica no worker. Autentica na casa. A casa é que, **por
ele**, apresenta cada trabalho à máquina.

---

## Um dia de trabalho da Ana

1. A Ana entra na casa dela. Nenhuma máquina está envolvida.
2. Manda um trabalho: instrução, repositório que a casa conhece, nome do
   environment. Não manda chaves, modelo, plugin nem «corre no VPS 3».

   ```bash
   curl -X POST http://ana.lan:4010/api/v1/jobs \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"schema_version":1,"idempotency_key":"k1","correlation_id":"c1",
          "repo":"app","environment":"review",
          "payload":{"instruction":"revê o PR 42","title":"review-42"}}'
   ```
3. A casa admite o trabalho como **dela** e captura o retrato fechado do
   que foi aceite: repositório, environment, preset, plugin, com digest.
   Um reload posterior da casa não move o chão debaixo do job.
4. Uma máquina livre pergunta às casas que serve: «tenho sítio, há
   trabalho?». Não escolhe pessoa. Pega um trabalho de quem tiver fila.
5. A casa da Ana oferece **este** trabalho. A máquina autentica a casa
   pelo token de worker dessa casa e aceita o trabalho num slot local.
   Não pede a password da Ana.
6. A máquina abre uma sandbox descartável só para este trabalho. O
   agente trabalha lá dentro. Quando acaba, a sandbox some.
7. Se o agente precisa de um modelo, de ferramentas ou de pacotes, fala
   com a **casa da Ana** através de um token assinado por job. A chave do
   modelo vive na casa. Se a máquina não chega a essa casa, recusa o
   trabalho; não o corre «pela casa do lado».
8. Se o resultado é uma branch, o agente escreve e faz commit **dentro**
   da sandbox, mas não empurra para o remoto canónico. Quem publica,
   depois das regras da casa, é a máquina, para o remoto **deste**
   trabalho, e diz à casa da Ana: aqui está a branch, estes são os
   commits. Se o resultado são ficheiros, a máquina entrega o blob à casa.
9. A Ana vê o resultado na casa dela. A casa do João responde 404 para
   esse job. O próximo trabalho nesse VPS pode ser do João. Os espelhos
   Git na máquina ficam em pastas separadas por casa.

Contrato HTTP: [api/jobs-openapi.json](api/jobs-openapi.json). Prova:
`mise run e2e:two-houses`, que corre um trabalho da Ana e um do João em
paralelo no mesmo worker, mata a casa da Ana, verifica que a do João
continua, e volta a levantar a da Ana sem re-enrolar.

---

## Pagar o modelo: gateway ou subscrição

**Gateway.** A chave (`api_key`) fica na casa. O contentor recebe um
token de trabalho e fala com o gateway da casa dona. O VPS não tem
ficheiro nenhum.

**Subscrição.** Os harnesses com login (`claude-code`, Codex, OpenCode
host auth) usam um ficheiro do **ferro**, declarado na casa como
`host_credentials`:

```toml
[host_credentials.claude-local]
kind = "claude-code"
credentials = "~/.claude/.credentials.json"
```

O `~/` **não** é expandido ao carregar a casa. Viaja na forma declarada e
é a máquina que copia, no momento da tentativa, que o expande para o home
do processo que corre o Docker. O operador fez `claude login` como o
utilizador que corre o worker; a Ana não viaja. Paths absolutos passam
como estão; `./` e `../` são recusados. Ficheiro em falta nessa máquina
falha a tentativa, sem procurar noutro sítio. `worker.toml` continua sem
credenciais.

| | Gateway | Subscrição |
|---|---|---|
| Onde vive a chave | casa | ficheiro do host, declarado na casa |
| No contentor | token de trabalho | cópia por tentativa em `/run/omashiki/state` |
| Permanente no VPS | não | só o login do ferro |
| Casa inacessível | recusa | recusa |

Prova: `server/test/omashiki/runtime/host_credentials_test.exs`.

---

## A cara do agente: identidades

O agente pode ter uma identidade GitHub. Declara-se **na casa**, no
agente, ao lado do resto:

```toml
[identities.ana-bot]
kind = "github-app"
app_id = "123456"
installation_id = "987654"
private_key = "${env:ANA_GITHUB_APP_PRIVATE_KEY}"

[presets.reviewer]
plugin = "opencode"
identities = ["ana-bot"]

[environments.review]
preset = "reviewer"
capabilities = ["github_*"]
# runtime, sink, credentials, ...
```

A chave só pode ser `${env:VAR}`; uma chave literal ou uma variável vazia
falham o boot. Um preset a nomear uma identity que não existe falha o
boot. Várias presets podem vestir a mesma identity. O environment não
tem campo `identities`.

Enquanto o trabalho corre, a sandbox vê um servidor MCP chamado
`ana-bot`. Quando o agente chama `github_comment`, `github_add_labels`,
`github_get_issue` ou `github_create_pull_request`, é a **casa** que age
como a App: assina o JWT, obtém o token de instalação e fala com o GitHub.
A sandbox e o worker só têm o token de job. O environment admitido leva o
nome, o kind e os ids públicos; a chave privada nunca sai da casa. Se a
casa deixar de declarar a identity, ou a declarar como outra App, a
chamada é recusada. A allowlist `capabilities` do environment aplica-se a
estas tools como a qualquer servidor MCP.

Prova: `server/test/omashiki/config/identity_test.exs`,
`server/test/omashiki/identities/broker_test.exs`.

---

## Uma issue chega à casa: o cliente à porta

O handler ouve o GitHub e fala com **a casa**; o VPS nunca vê o webhook.

| Quem | No GitHub | No Omashiki |
|---|---|---|
| A casa da Ana | aceita o trabalho e guarda o resultado | a casa dela |
| O GitHub App | ouve a issue e comenta no fim | um cliente de trabalho da casa |
| A máquina | nada | corre o job; não sabe que existe GitHub |

1. Alguém etiqueta a issue. O GitHub chama o handler. Isto ainda não é
   Omashiki.
2. O handler verifica a assinatura do GitHub e manda à casa da Ana um
   envelope: nome do environment, instrução, contexto (número, título,
   labels). Sem chaves, sem modelo, sem «corre no VPS 3».
3. A casa admite o trabalho como dela. Uma máquina livre corre-o e
   devolve o resultado só à casa.
4. A casa manda um webhook terminal assinado ao handler. O handler é que
   comenta ou etiqueta a issue, com o token dele.

Exemplo pronto, só stdlib:
[examples/handler/github_issue_handler.py](../examples/handler/github_issue_handler.py).
Segredo do webhook e mapeamento de eventos vivem no handler, nunca em
`omashiki.toml`.

---

## O que nunca acontece

- Um developer a entrar num VPS, por SSH ou por login no nó.
- Uma máquina com utilizadores («conta da Ana neste worker»).
- A máquina a guardar a password da Ana, a chave do modelo dela, ou a
  lista dos trabalhos dela.
- A máquina a devolver o resultado da Ana para a casa do João.
- O agente, dentro da sandbox, a empurrar sozinho para o remoto canónico.
- A chave privada da App, o segredo do webhook ou o token de instalação a
  irem no trabalho, na sandbox, ou para o VPS.
- O webhook do GitHub a chegar à máquina.
- A pasta `~/.claude` da Ana montada no VPS.
- `host_credentials` ou identidades no `worker.toml`.
- Um `include` em cadeia, ou um segundo ficheiro a «ganhar» o mesmo nome.
- Path relativo solto (`./` ou `../`) como origem de credencial.
- Uma App da organização a despejar issues na casa da Ana **e** na do
  João. O sistema é cliente **de uma casa**.

---

## As provas, e porque não são a mesma

| Prova | Quem prova | A quem | O que significa |
|---|---|---|---|
| A máquina é da frota | o VPS | as casas que tu enrolaste | «posso correr trabalho» |
| Esta pessoa é a Ana | a Ana | **só** a casa da Ana | «posso mandar e ver os *meus* trabalhos» |
| Este trabalho é deste job | a casa da Ana | a máquina, **neste** trabalho | «corre isto; devolve só a mim; fala comigo para o modelo» |
| Este cliente é o App da Ana | o handler | **só** a casa da Ana | «posso mandar trabalho e receber o fim» |

O GitHub prova-se ao handler; o handler prova-se à casa; a casa prova o
**job** à máquina. Ninguém salta um degrau.

---

## O que vive onde

**Na casa.** Quem o developer é. A fila. O que ele declarou que pode
correr. As chaves do modelo. O histórico. O resultado publicado. As
identidades dos agentes, chave incluída. A lista `include`. A declaração
de `host_credentials` (kind e forma do path, não o ficheiro do ferro). Os
clientes à porta e o sítio onde os avisar.

**Na máquina.** Capacidade. Docker. O sítio temporário da sandbox. O
espelho Git **daquele** trabalho, separado por casa. O ficheiro de
subscrição do ferro no `~/` deste processo, se o environment usa
subscrição; depois a cópia por tentativa e o descarte. As casas
enroladas: id, URL e token de cada uma.

**Em lado nenhum da máquina, nunca.** Password do developer. Chaves de
API do modelo. A base de dados da casa. Os outros trabalhos da mesma
pessoa. Chave privada do GitHub App, segredo do webhook, token de
instalação.

**No handler, à frente da casa.** Segredo do webhook do GitHub.
Mapeamento de eventos. A App como **cliente** que POSTa trabalho.

---

## Garantias

Cada linha é uma promessa do produto e, em itálico, onde o código a
sustenta.

1. Ligas N VPS uma vez; os devs não ligam VPS.
   *Worker arranca sem casa; casas chegam por enrollment. `e2e:two-houses`.*
2. Cada dev vive na casa dele.
   *Uma base de dados, um registry e um token de worker por casa; o worker não monta a base.*
3. O dev autentica-se na casa; a casa autentica o **job** na máquina.
   *Token de worker por casa no poll; claims assinados por job no data-plane.*
4. A máquina não tem utilizadores.
   *O worker só conhece id, URL e token de cada casa; `worker.toml` não tem credenciais.*
5. O mesmo VPS corre a Ana e o João sem saber os nomes.
   *Um job de cada casa em paralelo no mesmo worker; espelhos por id de casa.*
6. A chave do modelo da Ana nunca mora no VPS.
   *`api_key` fica na casa; o contentor fala com o gateway da casa dona.*
7. O resultado da Ana só existe na casa da Ana.
   *`Complete` e blobs só para o manager que ofereceu; a outra casa responde 404.*
8. Tirar a Ana da frota não desliga as máquinas nem o João.
   *`DELETE /internal/enroll/<id>`; kill e restart de uma casa provados no E2E.*
9. A identidade GitHub do agente vive na casa, não no VPS.
   *`[identities.<name>]`, kind `github-app`, chave só `${env:VAR}`.*
10. O trabalho não carrega chave de App; o `worker.toml` não tem GitHub.
    *A admissão remove `private_key`; o offer leva nome, kind e ids públicos.*
11. A máquina não precisa de saber que a issue veio do GitHub.
    *O handler manda instrução, contexto e nome do environment; nada mais.*
12. O cliente à porta da Ana não despeja trabalho na casa do João, e a identidade de uma casa não serve outra.
    *Token de API por casa; o broker resolve a identity pelo nome admitido e recusa se a casa a mudou.*
13. Um ficheiro ou vários, o produto é o mesmo.
    *Mesmo digest para monólito e split.*
14. `include` só na raiz; nome repetido falha o boot.
    *`Config.Error` na colisão; profundidade um; sem sair da pasta da casa.*
15. Quem POSTa escolhe o **nome** do environment.
    *Campo `environment` da admissão.*
16. `~/` em `host_credentials` expande na máquina que corre o container.
    *A forma com `~/` viaja no snapshot; a cópia expande contra o `HOME` do processo.*
17. Jira/MCP não é identity; GitHub App é.
    *`identities.kind` só aceita `github-app`; Jira fica em `mcp_servers` do environment.*

---

## Limites conhecidos

- O broker da identity foi provado contra um GitHub simulado, com JWT
  verificado pela chave pública, não contra uma App real.
- Só o harness opencode recebe a configuração MCP que lista a identity;
  Claude e jcode ainda não veem o servidor `ana-bot`.
- Não é a Ana escolher «quero o GPU-1». A casa manda trabalho; a frota
  coloca-o onde houver sítio.
- Uma só casa com muitos logins de developers é outro produto: uma
  empresa, uma fila, um dono.
- Refresh OAuth escreve na cópia por tentativa; não há write-back para o
  `~/` de ninguém.

Como se chegou aqui, fase a fase:
[internal/house-fleet-implementation.md](internal/house-fleet-implementation.md).
