---
title: "Copilot + OpenTelemetry + Grafana"
description: "Deployer une stack locale et observer les vraies traces et metriques de Copilot CLI et du Chat VS Code."
---

## Objectif de la demo

Montrer une requete Copilot reelle, puis retrouver sa trace, sa duree et ses
tokens dans Grafana. Le modele local de la premiere demo reste fourni par LiteLLM
et Ollama. OpenTelemetry est configure **dans le client Copilot**, pas dans
LiteLLM : les spans montrent donc l'orchestration du client et ses appels LLM.

```text
Copilot CLI / Chat VS Code ---> LiteLLM ---> Ollama / Qwen 3
        |
        | OpenTelemetry, contenus desactives
        v
OTLP/HTTP :4318 ou OTLP/gRPC :4317
        |
        v
Collector ---> Tempo       (traces)
          ---> Prometheus  (metriques)
          ---> Loki        (evenements si le client en emet)
                    |
                    v
              Grafana :3000
```

Le collector et les backends sont regroupes dans l'image officielle
`grafana/otel-lgtm:0.37.0`, destinee au developpement et aux demos.
Cette stack est un projet Compose separe de LiteLLM et ne l'arrete pas.
Le script de demarrage recree son conteneur pour charger les fichiers de dashboard
mis a jour, tout en conservant le volume de donnees.

> [!IMPORTANT]
> Ce n'est ni un rapport d'usage de toute l'entreprise, ni une mesure de
> productivite, ni un releve de facturation Copilot. Seuls les clients
> explicitement configures envoient des donnees. Les outils non invoques
> n'ont pas de spans, et les signaux disponibles dependent du client/version.

## 1. Verifier les prerequis

- Docker Desktop demarre avec les conteneurs Linux
- PowerShell 7.4 ou plus recent
- Copilot CLI installe, avec `copilot help monitoring` disponible
- LiteLLM et Ollama demarres selon le [README principal](../README.md)
- Plusieurs Go de disque et de memoire libres pour la stack supplementaire
- Ports locaux 3000, 4317 et 4318 disponibles

Depuis la racine du depot, pas depuis `observability` :

```powershell
$env:DOCKER_CONTEXT = 'desktop-linux'
copilot --version
copilot help monitoring
docker compose ps
```

Si LiteLLM est arrete :

```powershell
.\scripts\start-demo.ps1
```

N'executez pas de nettoyage Docker global entre les deux demos.

## 2. Deployer Grafana et le collector

```powershell
.\observability\start-demo.ps1
```

Attendez `Ready`, puis ouvrez :

<http://127.0.0.1:3000/d/copilot-otel-demo>

Grafana s'ouvre sans connexion avec un acces anonyme en lecture seule.
Le mot de passe d'administration est aleatoire, genere au premier lancement dans
`observability\.env`, ignore par Git. Aucun mot de passe fixe n'est publie.
Les quatre panneaux restent vides tant qu'aucune metrique CLI n'est arrivee.

```powershell
docker compose -f .\observability\docker-compose.yml ps
```

Resultat attendu : le service `lgtm` est `healthy`.
Seuls Grafana et les entrees OTLP sont exposes, uniquement sur `127.0.0.1`.
Les API Tempo, Prometheus et Loki sont consultees via le proxy Grafana.

## 3. Generer de vraies donnees Copilot CLI

Creez une cle individuelle LiteLLM sans l'afficher :

```powershell
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias demo-otel
```

Lancez la verification complete :

```powershell
.\observability\test-demo.ps1
```

Le script :

1. Envoie un vrai prompt via Copilot CLI vers LiteLLM et Qwen 3.
2. Exige la reponse exacte `COPILOT_OTEL_OK`.
3. Recherche dans Tempo l'identifiant unique de cette execution, sans accepter
   une ancienne trace comme preuve.
4. Verifie les spans GenAI `invoke_agent` et `chat`.
5. Verifie l'absence des attributs de contenu dans ces spans et leurs evenements.
6. Exige une metrique de tokens dont le timestamp est posterieur au debut du test.
7. Execute les requetes des quatre panneaux et exige des valeurs positives.

La ligne `Trace ID` est l'identifiant a ouvrir dans Tempo.
La collecte est asynchrone : laissez au collector quelques secondes apres la
fin de l'appel. Le test attend jusqu'a 90 secondes apres la sortie du client.
Il echoue explicitement si les donnees attendues ne sont pas presentes.
Il ne fabrique pas de traces et ne se contente pas d'un conteneur en bonne sante.

### Verification realisee le 19 octobre 2026

Avec Copilot CLI 1.0.98 et la stack LGTM 0.37.0, un vrai appel Qwen 3 via
LiteLLM a produit une trace contenant `invoke_agent` et `chat`, sans attributs
de contenu captures. Une metrique de tokens fraiche et les quatre requetes du
dashboard ont ete validees. Le comptage des appels filtre bien l'operation
`chat`, sans ajouter le span d'orchestration.

La recreation du conteneur a conserve les donnees des executions precedentes.
Le parcours VS Code et les evenements Loki n'ont pas ete valides dans l'interface.

Pour une autre question :

```powershell
.\observability\run-copilot-cli.ps1 --no-custom-instructions --disable-builtin-mcps --silent --prompt '/no_think Explique en deux phrases le role d OpenTelemetry. Ne lance aucun outil.'
```

Ou pour une session interactive :

```powershell
.\observability\run-copilot-cli.ps1 --no-custom-instructions --disable-builtin-mcps
```

Quittez normalement la session pour permettre au client de terminer ses exports.
Le wrapper configure OTLP/HTTP protobuf sur `http://127.0.0.1:4318` et le service
`copilot-cli-demo`. Les variables OTel heritees sont remplacees pendant cet appel,
puis restaurees, pour eviter qu'un ancien endpoint, un export fichier ou des
headers de production prennent la priorite. Aucun reglage global n'est modifie.
Le modele utilise reste Qwen 3, comme dans la premiere demo.

## 4. Lire le dashboard et les traces

Dans le [dashboard Copilot](http://127.0.0.1:3000/d/copilot-otel-demo), montrez :

- Les tokens entrants
- Les tokens sortants
- Le nombre d'appels LLM
- La duree moyenne des appels LLM

Les panneaux affichent les dernieres series cumulees exportees par le CLI.
Ils filtrent `gen_ai_operation_name="chat"` pour ne pas compter une seconde fois
les mesures d'orchestration `invoke_agent`. La derniere valeur est recherchee
dans la plage de temps du dashboard, meme si le processus CLI a deja termine.
Ces compteurs peuvent repartir de zero au lancement d'un nouveau processus ;
ils ne representent pas un cumul fiable de toutes les sessions.
La duree est celle de l'appel cote client, pas uniquement le calcul du modele.
Si plusieurs instances ont exporte pendant la plage selectionnee, les panneaux
additionnent leur derniere valeur disponible : apres trois executions de test
avec un appel LLM chacune, le panneau des appels affiche trois.

Pour les traces :

1. Ouvrez **Explore** dans Grafana.
2. Selectionnez la source **Tempo**.
3. Choisissez l'editeur **TraceQL** et une plage de temps couvrant la demo
   (par exemple les 30 dernieres minutes).
4. Executez la requete suivante.

```traceql
{ resource.service.name = "copilot-cli-demo" }
```

Ouvrez une trace. L'arbre montre un span d'orchestration `invoke_agent` et
ses appels `chat`. Inspectez les attributs `gen_ai.operation.name`,
`gen_ai.request.model` et, quand le client les renseigne,
`gen_ai.usage.input_tokens` / `gen_ai.usage.output_tokens`.
Le span d'orchestration CLI peut afficher l'identifiant de compatibilite
`gpt-4.1` du lanceur ; le span `chat` identifie le vrai modele demande, `qwen3:4b-8k`.

Pour retrouver uniquement l'execution qui vient d'etre testee, reprenez le
`Local telemetry run` affiche par le script :

```traceql
{ resource.service.name = "copilot-cli-demo" && resource.demo.run_id = "<identifiant affiche>" }
```

Le prompt du smoke test interdit les outils : aucun span `execute_tool` n'est
attendu. Dans une session qui utilise effectivement un outil, le client peut
emettre ce span. Ne presentez pas un outil theorique comme un outil execute.

## 5. Configurer le Chat VS Code

La configuration du CLI n'active pas l'export du Chat VS Code.
Utilisez une version de l'extension Copilot Chat qui expose les parametres
`github.copilot.chat.otel.*`.

1. Ouvrez le depot dans VS Code.
2. Avec `Ctrl+Shift+P`, ouvrez **Preferences: Open User Settings (JSON)**.
3. Ajoutez les proprietes du [fichier de reference](vscode-settings.json)
   dans vos reglages utilisateur existants, sans ecraser les autres.
4. Rechargez la fenetre avec **Developer: Reload Window**.
5. Dans le Chat, choisissez le modele LiteLLM configure selon l'etape 6
   du [README principal](../README.md). Ce choix est distinct de la configuration OTel.
6. Ouvrez un nouveau chat sans fichiers sensibles et envoyez :

```text
/no_think Reply with exactly VSCODE_OTEL_OK and nothing else.
```

Les reglages a ajouter :

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "http://127.0.0.1:4318",
  "github.copilot.chat.otel.captureContent": false
}
```

Dans Grafana **Explore > Tempo**, lancez :

```traceql
{ resource.service.name = "copilot-chat" }
```

Le nom par defaut est `copilot-chat`, mais `OTEL_SERVICE_NAME` herite au demarrage
de VS Code peut le modifier. Les variables d'environnement prennent la priorite
sur les reglages VS Code. Si VS Code avait ete lance depuis un terminal avec des
variables OTel, quittez et relancez-le depuis un terminal propre.

> [!NOTE]
> Ce parcours vise l'instrumentation de l'extension Copilot Chat. Les sessions
> background CLI, Agent Host ou cloud peuvent utiliser un autre moteur et
> necessiter leur propre configuration. Les suggestions inline ne sont pas
> automatiquement des traces d'orchestration Chat.

Ne declarez le parcours graphique valide qu'apres avoir constate la reponse
et une nouvelle trace `copilot-chat` dans Tempo.
Le dashboard fourni est centre sur les metriques CLI : utilisez Explore pour
les signaux VS Code plutot que de supposer des noms identiques.

Pour les metriques VS Code, source **Prometheus**, commencez par :

```promql
{service_name="copilot-chat", __name__=~"gen_ai_.*|copilot_chat_.*"}
```

Pour les evenements, source **Loki**, essayez :

```logql
{service_name="copilot-chat"}
```

L'extension documente notamment des evenements de session et d'appel LLM.
La presence de Loki ne garantit pas qu'un client ou un mode d'execution exporte
des logs. Le CLI utilise pour cette demo documente surtout les traces et metriques ;
une requete Loki vide pour le CLI n'est donc pas une preuve d'echec.

## 6. Montrer la confidentialite et les limites

La capture des contenus est desactivee. Les scripts n'activent ni la collecte
des prompts/reponses, ni celle du code, ni celle des arguments/resultats des outils.
Les attributs de modele, duree, tokens, identifiants de session et metadonnees
techniques restent des donnees potentiellement sensibles. L'absence de contenu
n'est pas une garantie d'anonymisation.

Le collector local n'ajoute pas de hachage d'identite ni de redaction universelle.
N'activez pas `captureContent` pendant une demo client et n'envoyez pas de donnees
sensibles. Les backends sont consultables par tout processus/utilisateur local
ayant acces aux ports de la machine. L'ingestion OTLP n'a pas d'authentification.

Cette demo ne remplace pas les API de metriques d'usage Copilot de GitHub.
Elle n'installe pas une politique centralisee sur les postes et ne couvre pas
automatiquement les activites effectuees dans GitHub.com ou d'autres clients.
La gouvernance d'un deploiement entreprise implique consentement/information,
controle d'acces, TLS, retention, filtrage et politiques des terminaux.

## 7. Arreter et relancer

```powershell
.\observability\stop-demo.ps1
```

Les donnees et le dashboard persistent dans le volume de la stack.
LiteLLM continue de tourner. Pour arreter aussi le modele :

```powershell
.\scripts\stop-demo.ps1
```

Dans VS Code, remettez `github.copilot.chat.otel.enabled` a `false`, puis rechargez
la fenetre quand vous n'utilisez plus le collector. Retirez aussi les variables
OTel que vous auriez configurees manuellement ; un endpoint herite peut reactiver
l'instrumentation.

Pour rejouer :

```powershell
.\scripts\start-demo.ps1
.\observability\start-demo.ps1
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias demo-otel
.\observability\test-demo.ps1
```

> [!CAUTION]
> `docker compose -f .\observability\docker-compose.yml down --volumes`
> efface les donnees de telemetrie de cette stack. Ce n'est pas la commande
> d'arret normal. Ne lancez pas de suppression globale des volumes Docker.

## Depannage

| Symptome                       | Verification                                                                                 |
|--------------------------------|----------------------------------------------------------------------------------------------|
| Port occupe                    | Identifier l'application qui utilise 3000, 4317 ou 4318 avant de modifier quoi que ce soit      |
| Conteneur non healthy          | `docker compose -f .\observability\docker-compose.yml logs --tail 80`                           |
| Grafana vide                   | Generer un appel CLI, attendre l'export, puis verifier la plage de temps                       |
| Modele ou cle indisponible     | Rejouer le README LiteLLM et recreer une cle individuelle                                      |
| Aucune trace de la nouvelle run | Verifier l'exporter HTTP et l'endpoint, puis `copilot help monitoring`                          |
| HTTP avec variables TLS CLI    | Le CLI peut desactiver l'export HTTP si des variables de certificat sont heritees ; le wrapper les isole |
| VS Code ne montre pas OTel     | Verifier la version de l'extension, les politiques et les parametres disponibles                |
| VS Code exporte ailleurs       | Les variables d'environnement priment sur les settings ; relancer depuis un environnement propre |
| Traces mais metriques absentes | Attendre l'export des metriques et quitter normalement le CLI pour permettre le flush          |
| Loki vide pour le CLI          | Le smoke test ne promet pas de logs CLI ; verifier les traces et metriques                     |

## Sources officielles

- Copilot CLI installe : `copilot help monitoring` et `copilot help environment`
- [VS Code : OpenTelemetry pour les interactions agent](https://code.visualstudio.com/docs/enterprise/telemetry#_opentelemetry-support-for-agent-interactions)
- [Copilot Chat : guide officiel de monitoring](https://github.com/microsoft/vscode-copilot-chat/blob/main/docs/monitoring/agent_monitoring.md)
- [Grafana : Docker OpenTelemetry LGTM](https://grafana.com/docs/opentelemetry/docker-lgtm/)
- [Image et composants LGTM](https://github.com/grafana/docker-otel-lgtm/tree/v0.37.0)
