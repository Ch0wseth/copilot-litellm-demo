---
title: "POC VS Code : recuperation automatique d'une cle LiteLLM"
description: "Installer depuis les sources un fournisseur VS Code et son broker local, tester une vraie reponse et distinguer le test API du Chat standard."
---

# POC VS Code : extension et cle LiteLLM dynamique

Ce guide permet de reproduire le POC sur **votre propre poste Windows** avec
les fichiers du depot. Il remplace la saisie d'une cle LiteLLM dans
`chatLanguageModels.json` par un fournisseur de modeles VS Code et un broker local.

Ce n'est pas une fonctionnalite native `${get_api_key.py}` du champ `apiKey`.
L'extension appelle le broker avant une requete ; le broker cree ou reutilise
une cle virtuelle individuelle limitee au modele de la demo.

```text
VS Code : fournisseur litellm-dynamic-key-poc
       |
       | jeton local du broker, pas la master key
       v
Broker : 127.0.0.1:43128
       |
       | master key du .env local -> /key/generate
       v
LiteLLM : 127.0.0.1:4000 -> PostgreSQL
       ^
       | cle virtuelle obtenue par l'extension
       | POST /v1/chat/completions
       |
VS Code : fournisseur -> LiteLLM -> Ollama -> Qwen
```

## 1. Choisir le bon parcours

| Besoin | Parcours |
|--------|----------|
| Utiliser une cle fournie, sans extension maison | [Custom Endpoint et saisie manuelle](../vscode/README.md) |
| Demontrer la recuperation automatique sur un poste de test | Ce guide, extension + broker local |
| Recuperer une cle dans Copilot CLI ou une session SDK | [Guide CLI/SDK](../copilot-app-dynamic-key/README.md) |
| Equiper les utilisateurs d'une passerelle d'entreprise | Adapter l'architecture avec un service distant authentifie ; ce POC seul ne suffit pas |

Le code fourni traite du texte et annonce `toolCalling: false` et
`imageInput: false`. Il vise un chat court en mode **Ask**, pas une session
Agent avec outils, des suggestions inline, des embeddings ou des images.

### Ce qui a ete verifie

Le 3 novembre 2026, avec VS Code 1.145.0, Node.js 22.23.4 et la vraie stack
LiteLLM/Ollama locale :

| Verification | Resultat |
|--------------|----------|
| Tests Node avec serveurs et cles factices | 2 tests reussis |
| Decouverte du modele avec `vscode.lm.selectChatModels` | Reussie |
| Obtention automatique d'une cle et authentification LiteLLM | Reussies |
| Commande Run Test Prompt, via `LanguageModelChat.sendRequest` | Marqueur `VSCODE_DYNAMIC_KEY_POC_OK` recu |
| Requete correspondante dans LiteLLM | HTTP `200` observe |
| Selection puis prompt dans le Chat VS Code standard avec ce fournisseur | Pas encore valide |
| Rotation apres une heure, revocation reelle a l'arret, SSO, deploiement multi-utilisateur | Pas valides par ce test |

Le test API reussi prouve le chemin fournisseur -> broker -> LiteLLM -> modele.
Il **ne prouve pas** a lui seul que le selecteur du Chat standard expose le
modele ou qu'une conversation de cette interface aboutit. L'etape 7 est la
validation finale de ce parcours utilisateur.

## 2. Prerequis et limites de securite

- Windows et PowerShell 7.4 ou plus recent.
- Git, Node.js 22 ou plus recent et VS Code. Pour reproduire le test,
  utiliser VS Code 1.145.0 ou une version plus recente avec l'API fournisseur.
- Docker Desktop demarre en mode conteneurs Linux.
- Plusieurs Go libres pour les images, les poids Qwen et le modele en memoire.
- Ports loopback 4000, 11434 et 43128 disponibles.
- Un workspace **local**, pas Remote SSH, WSL ni un Dev Container pour ce POC.

Copilot CLI et la GitHub Copilot app ne sont pas necessaires. Aucun
`npm install`, build JavaScript ou appel a un modele heberge n'est requis :
l'extension utilise des modules Node natifs et l'API `vscode`.

> [!WARNING]
> Le broker est un POC monoposte : tout processus du meme compte Windows
> peut potentiellement lire son fichier de jeton ou l'appeler. Le mode de
> fichier demande par Node ne constitue pas une garantie d'ACL NTFS.
> Proteger les fichiers locaux avec les droits de votre poste et utiliser
> uniquement les secrets d'une passerelle de demonstration que vous administrez.

La master key reste dans le `.env` et le processus broker ; elle n'est jamais
envoyee a l'extension. Le broker renvoie une cle virtuelle : cela protege le
chemin d'appel du client, **pas l'ensemble du poste**, qui possede le `.env`.
Ne mettez jamais la master key d'une entreprise sur les postes utilisateurs.
Le jeton local du broker n'est ni une authentification GitHub ni une identite SSO.

Les API locales utilisent HTTP et Ollama reste accessible aux processus locaux
sans authentification. Ce code ne durcit pas la stack pour la production.
Une politique Copilot Business/Enterprise peut desactiver BYOK ; ne la contournez pas.

## 3. Cloner et demarrer votre propre stack

Ouvrez PowerShell. Si le depot est deja clone, placez-vous a sa racine au lieu
de le cloner une seconde fois.

```powershell
git clone https://github.com/Ch0wseth/copilot-litellm-demo.git
Set-Location .\copilot-litellm-demo
$PSVersionTable.PSVersion
node --version
code --version
docker info --format '{{.ServerVersion}}'
```

Sur Docker Desktop Windows, si necessaire :

```powershell
$env:DOCKER_CONTEXT = 'desktop-linux'
```

Verifiez les ports **avant** le demarrage :

```powershell
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 4000, 11434, 43128 } |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

Si un port est utilise par une autre stack, ne la stoppez pas arbitrairement.
Un autre nom Compose isole les volumes, mais les deux stacks ne peuvent pas
publier les memes ports. Ce guide conserve les ports fixes attendus par le code.

### Terminal A : stack nommee

Depuis la racine du depot :

```powershell
$env:COMPOSE_PROJECT_NAME = 'vscode-dynamic-key-poc'
.\scripts\start-demo.ps1
docker compose ps
docker compose exec -T ollama ollama list
```

Le script genere `.env` s'il n'existe pas, demarre PostgreSQL/Ollama,
telecharge Qwen, cree `qwen3:4b-8k`, puis demarre LiteLLM. Attendez :

```text
Demo ready: LiteLLM http://127.0.0.1:4000; Ollama http://127.0.0.1:11434
```

Ce nom Compose donne des volumes distincts des projets portant un autre nom.
Il reutilise toutefois le `.env` de cette copie du depot. Les variables
d'environnement ne persistent pas entre terminaux : definissez le meme
`COMPOSE_PROJECT_NAME` dans chaque terminal qui utilise les scripts Docker.

Le `.env` contient `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`,
`POSTGRES_PASSWORD` et `DATABASE_URL`. **Aucune valeur n'est a remplir ni a
copier depuis le poste d'un autre utilisateur** pour une nouvelle stack.
Il est ignore par Git. Ne l'affichez pas et ne le joignez pas a un message.

Si le volume PostgreSQL existe deja, ne supprimez pas son `.env` pour
"repartir a zero" : regenerer le fichier ne change pas les identifiants deja
enregistres dans la base. Conserver une sauvegarde securisee et consulter le
[guide de la stack](../README.md) avant tout nettoyage destructif.

## 4. Demarrer le broker

Dans le **terminal A**, une fois la stack prete :

```powershell
.\vscode-dynamic-key-poc\scripts\start-broker.ps1
```

Le terminal reste occupe : gardez-le ouvert. Resultat attendu :

```text
Local key broker listening on http://127.0.0.1:43128
The broker token is stored in the current Windows user profile.
```

Le lanceur lit la master key du `.env` sans l'afficher et la transmet
uniquement au processus broker. Il genere un jeton aleatoire dans :

```text
%LOCALAPPDATA%\CopilotLiteLLMPoc\broker-token
```

L'extension du meme compte Windows lit ce fichier pour s'authentifier au
broker. Il ne faut pas copier ce jeton dans `chatLanguageModels.json`.
Un seul broker peut utiliser ce port et ce fichier a la fois.

Dans un **terminal B**, a la racine du depot :

```powershell
$env:COMPOSE_PROJECT_NAME = 'vscode-dynamic-key-poc'
Invoke-RestMethod -Uri 'http://127.0.0.1:43128/healthz' -TimeoutSec 5
```

Resultat attendu : `status` vaut `ok`. `/healthz` ne cree pas de cle et ne
valide pas LiteLLM : la commande Check Connection de l'etape 6 le fait.

## 5. Charger le code de l'extension dans un profil isole

Ce depot fournit une extension **depuis ses sources**, pas une extension
Marketplace ni un VSIX publie. Il suffit de charger le dossier
`vscode-dynamic-key-poc\extension` ; aucun packaging n'est necessaire pour ce POC.

Dans le **terminal B**, toujours depuis la racine :

```powershell
code --new-window `
  --user-data-dir "$env:TEMP\litellm-dynamic-key-poc-profile" `
  --extensions-dir "$env:TEMP\litellm-dynamic-key-poc-extensions" `
  --extensionDevelopmentPath "$PWD\vscode-dynamic-key-poc\extension" `
  "$PWD"
```

Verifiez que le titre contient **[Extension Development Host]**. Les donnees
et les extensions installees de ce profil sont stockees dans les deux
repertoires temporaires nommes ci-dessus, pas dans le profil principal.
Les memes chemins permettent de retrouver ce profil lors d'un nouveau lancement.

N'ajoutez pas de cle via Custom Endpoint pour cette extension : son
fournisseur s'appelle **LiteLLM Dynamic Key POC**. Le JSON du parcours
manuel n'est pas utilise.

Si le workbench ne s'ouvre pas ou si vous aboutissez au mauvais profil,
enregistrez votre travail puis fermez vous-meme les fenetres VS Code avant
de rejouer la commande. Cette mesure a permis de relancer le workbench sur
le poste d'essai ; ne tuez pas tous les processus Code sans sauvegarde.

Le Chat ou le harness choisi peut demander une configuration, une confiance
workspace ou une connexion. Verifiez le chemin du depot avant de lui faire
confiance. Un compte connecte dans votre profil principal ne l'est pas
necessairement dans ce profil isole. Effectuez toute connexion demandee
vous-meme, via l'assistant officiel et le navigateur ; ne partagez pas vos
identifiants, codes ou jetons. Les commandes API de l'etape suivante ont
fonctionne sans connexion GitHub dans le profil d'essai.

## 6. Verifier le fournisseur sans passer par le Chat standard

Dans la palette `Ctrl+Shift+P` de la fenetre **Extension Development Host** :

1. Executez **LiteLLM Dynamic Key POC: Check Connection**.
2. Attendez **LiteLLM Dynamic Key POC is connected.**
3. Executez **LiteLLM Dynamic Key POC: Run Test Prompt**.
4. Attendez **VS Code provider returned the expected local model response.**

Check Connection demande a VS Code de decouvrir le modele, obtient une cle
via le broker, puis appelle `/v1/models` avec cette cle. Cela ne valide
pas encore une reponse d'inference.

Run Test Prompt utilise `vscode.lm.selectChatModels` puis
`LanguageModelChat.sendRequest`. Il envoie :

```text
/no_think Reply with exactly VSCODE_DYNAMIC_KEY_POC_OK and nothing else.
```

Il confirme la presence du marqueur dans le texte recu, sans afficher de cle.
La notification de succes n'est pas une conversation dans le panneau Chat.
Consultez le centre de notifications si une notification a disparu.

Dans un **terminal C**, a la racine, pour corroborer le test :

```powershell
$env:COMPOSE_PROJECT_NAME = 'vscode-dynamic-key-poc'
docker compose logs --tail 30 -f litellm
```

Une nouvelle requete `POST /v1/chat/completions` avec HTTP `200` doit
correspondre au test. Un ancien `200` ou un `/v1/models` reussi ne suffit pas.
N'activez pas les logs debug et ne joignez pas de prompts confidentiels.
`Ctrl+C` dans ce terminal arrete les logs, pas la stack.

## 7. Validation manuelle finale dans le Chat VS Code

Cette etape est **a effectuer sur votre installation** : elle n'a pas encore
ete validee avec ce fournisseur dans l'interface standard.

1. Dans la fenetre isolee, ouvrez le Chat standard de VS Code.
2. Si le parcours affiche **Sign In**, **Models** ou un assistant
   d'activation, examinez ses exigences et les politiques de votre compte.
   Les exigences de connexion varient selon le harness ; ne supposez
   pas qu'une cle LiteLLM les remplace.
3. Ouvrez **Chat: Manage Language Models** si necessaire et recherchez
   le fournisseur **LiteLLM Dynamic Key POC** deja contribue par l'extension.
   Sa commande de gestion est Check Connection ; elle ne demande pas de cle.
4. Dans le selecteur du Chat, choisissez
   **Qwen via LiteLLM (qwen3:4b-8k)**. Ne choisissez pas Auto ni le
   **Qwen 3 4B via LiteLLM** d'un ancien Custom Endpoint manuel.
5. Utilisez **Ask**, dans un nouveau chat sans fichier, image ni outil.
6. Envoyez le meme prompt `VSCODE_DYNAMIC_KEY_POC_OK` que ci-dessus.
7. Verifiez le texte affiche dans le Chat **et** une nouvelle requete
   `/v1/chat/completions` avec HTTP `200` dans les logs de cette stack.

Si le modele ne se trouve pas dans le selecteur, ne validez pas ce parcours
en remplacant le test par Run Test Prompt : ce serait un autre chemin.
Consultez les diagnostics de l'etape 10 et les politiques BYOK.

Un modele Qwen de 4B sur CPU peut mettre plusieurs minutes a repondre.
`/no_think` peut etre ignore selon le template. Le fournisseur utilise
`stream: false` : il transmet la reponse complete a VS Code une fois l'appel
termine, pas token par token.

## 8. Comprendre le code et ses points d'adaptation

| Fichier | Role |
|---------|------|
| `extension\package.json` | Declare le vendor, son nom, le point d'entree et les deux commandes |
| `extension\extension.js` | Enregistre le fournisseur avec `vscode.lm.registerLanguageModelChatProvider` et fixe les URL locales |
| `extension\provider.js` | Expose Qwen, lit le jeton du broker, obtient une cle et convertit les messages texte pour LiteLLM |
| `broker\server.mjs` | Authentifie les appels locaux, genere/cache/revoque les cles virtuelles |
| `scripts\start-broker.ps1` | Lit le `.env` local et prepare l'environnement du processus broker |
| `tests\poc.test.mjs` | Teste l'enregistrement et le flux avec des serveurs/cles factices |

### Flux d'une requete

1. VS Code appelle le fournisseur avec ses messages.
2. `getIndividualKey()` lit le jeton local et appelle `POST /v1/key` du broker.
3. Au premier appel, le broker utilise sa master key pour `POST /key/generate`.
4. LiteLLM cree une cle limitee a `qwen3:4b-8k`, avec une duree demandee de `1h`.
5. Le broker renvoie seulement cette cle virtuelle a l'extension.
6. L'extension appelle `POST /v1/chat/completions` avec la cle virtuelle.
7. Le texte recu est reporte comme `LanguageModelTextPart` dans VS Code.

Le broker reutilise sa cle en memoire pendant environ 55 minutes. Il est
appele avant chaque requete du fournisseur, mais **ne genere pas une
nouvelle cle a chaque prompt**. Le premier appel apres la marge de
rafraichissement cree une nouvelle cle et tente de revoquer la precedente.
Le cache et la duree ne constituent pas une identite utilisateur : le
`key_alias` aleatoire sert uniquement d'etiquette de demo.

L'annulation de la requete VS Code est relayee au `fetch` de Chat Completions.
Le comptage de tokens est une estimation de longueur de texte, pas le tokenizer
Qwen : evitez les grands contextes. Le code ne gere ni outils ni images.

### Reglages actuels

| Reglage | Ou l'adapter de facon coherente |
|---------|--------------------------------|
| Port LiteLLM `4000` | Compose, lanceur broker et URL de `extension.js` |
| Port broker `43128` | Lanceur broker, URL de `extension.js` et controles de ce guide |
| Modele `qwen3:4b-8k` | Configuration LiteLLM/Ollama, lanceur broker, extension, budgets et tests |
| Jeton local | Le lanceur et l'extension utilisent le meme chemin ; `LITELLM_POC_TOKEN_FILE` peut le remplacer |
| Duree `1h` et marge `5 min` | `broker\server.mjs`, constantes de duree et requete de generation |
| Budgets `7680` / `512` | Metadonnees et requete dans `provider.js`, contexte du modele |

Les URL HTTP sont volontairement limitees au loopback dans le broker et
le fournisseur. **Remplacer simplement l'URL par une URL distante ne
fonctionne pas** : cette variante n'est pas prise en charge par le code.
Les valeurs du lanceur remplacent aussi les variables preexistantes pour
viser explicitement la stack locale. N'utilisez pas ce script tel quel avec
la master key d'une autre passerelle.

### Pour un service d'entreprise

Le schema cible est extension utilisateur -> service d'emission authentifie
-> LiteLLM, avec la master key uniquement sur le serveur, dans un coffre.
L'adaptation exige au minimum une authentification utilisateur, HTTPS,
validation d'identite et autorisations de modele, expiration/rotation,
controle d'acces, gestion d'erreurs et journalisation sans secrets.

Il faut remplacer le courtage local et le fichier de jeton par ce contrat
de service, puis adapter les validations d'URL et les appels de l'extension.
Ce depot ne fournit pas ce service, une integration Entra ID, un deploiement
multi-utilisateur ni une politique centralisee VS Code. Ne distribuez pas
le `.env` ou le broker administrateur local aux utilisateurs d'une entreprise.

## 9. Tests automatises sans Docker ni VS Code

Depuis la racine du depot :

```powershell
node --test .\vscode-dynamic-key-poc\tests\poc.test.mjs
```

Les tests emploient des cles factices et des serveurs HTTP loopback temporaires.
Ils verifient l'enregistrement du fournisseur, la restriction du modele et
la duree demandee, le cache de cle sur plusieurs appels, le refus sans jeton,
une reponse de chat et une requete de revocation lors de la fermeture du broker.

Ces tests ne prouvent ni la connexion GitHub, ni le selecteur du Chat, ni
l'invalidation reelle d'une cle dans LiteLLM, ni la rotation apres 55 minutes.
Ils suppriment leur repertoire temporaire a la fin. Aucun secret du `.env`
n'est utilise.

## 10. Depannage

| Symptome | Controle et action |
|----------|--------------------|
| `.env` absent | Demarrer votre stack avec `start-demo.ps1`, pas copier les secrets d'un autre poste |
| Port occupe | Identifier son processus/projet ; ne pas tuer un service tiers ni faire de nettoyage Docker global |
| `/healthz` retourne une erreur | Verifier que le broker du POC tourne sur 43128 ; le chemin est `/healthz`, pas `/health` |
| Broker refuse en HTTP `401` | Jeton absent, perime ou mauvais chemin ; redemarrer proprement le broker et recharger le bon profil |
| Broker retourne HTTP `502` | Lire sa raison d'echec sans secrets ; verifier LiteLLM, `.env` et les droits d'emission de cles |
| LiteLLM refuse la cle | Cle revoquee/base recreee ; redemarrer le broker pour sortir de son cache, puis refaire Check Connection |
| Commande LiteLLM absente | Verifier le titre Extension Development Host, le chemin absolu de l'extension et sa version de VS Code |
| `registerLanguageModelChatProvider` indisponible | Mettre a jour VS Code vers une version avec cette API ; ne pas ajouter une cle manuelle pour masquer le probleme |
| Pas de workbench ou mauvais profil | Sauvegarder, fermer les fenetres puis relancer ; ne pas modifier le profil principal par erreur |
| Modele absent du Chat mais Check Connection reussi | Tester le Chat/harness local, la confiance, la configuration de compte et les politiques BYOK ; resultat API != resultat du selecteur |
| Pas de reponse ou marqueur absent | Nouveau prompt Ask court, attendre Qwen, regarder les notifications et les nouvelles requetes LiteLLM |
| WSL/SSH/Dev Container | Revenir a une fenetre locale : loopback et chemin du jeton peuvent viser une autre machine |

Si necessaire, ouvrez **Developer: Show Logs... > Extension Host** dans le
profil de test et relevez l'erreur. Ne partagez pas de logs bruts sans
verifier les prompts, les donnees et les secrets qu'ils pourraient contenir.

## 11. Arreter, relancer et nettoyer

Fermez seulement la fenetre de developpement du POC, puis appuyez sur
`Ctrl+C` dans le **terminal A du broker**. Le broker tente `/key/delete`
et supprime son fichier de jeton. Un arret brutal peut empecher cette
tentative ; la cle expire alors selon la duree demandee a LiteLLM.
La disparition du jeton ne prouve pas la revocation cote passerelle.

Pour arreter proprement le broker depuis un autre terminal du meme compte,
sans afficher le jeton :

```powershell
$tokenFile = Join-Path $env:LOCALAPPDATA 'CopilotLiteLLMPoc\broker-token'
$brokerToken = [System.IO.File]::ReadAllText($tokenFile).Trim()
try {
    Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:43128/v1/shutdown' `
        -Headers @{ Authorization = "Bearer $brokerToken" } |
        Select-Object status
} finally {
    Remove-Variable brokerToken
}
```

`stopping` confirme la demande d'arret, pas la revocation. Si le terminal
broker signale un echec de `/key/delete`, l'administrateur de la stack doit
verifier/revoquer la cle dans LiteLLM. N'affichez pas la cle pour le demontrer.

Puis, dans un terminal a la racine avec le bon nom Compose :

```powershell
$env:COMPOSE_PROJECT_NAME = 'vscode-dynamic-key-poc'
.\scripts\stop-demo.ps1
```

Cet arret conserve les volumes et le `.env`. Pour rejouer, refaire le
demarrage de la stack, du broker et de la fenetre avec les memes chemins.
Le broker genere un nouveau jeton de session et demande une nouvelle cle.

Si vous ne souhaitez pas conserver le profil de test, **apres avoir ferme
sa fenetre**, supprimez seulement ces deux repertoires :

```powershell
Remove-Item -LiteralPath "$env:TEMP\litellm-dynamic-key-poc-profile" -Recurse -Force
Remove-Item -LiteralPath "$env:TEMP\litellm-dynamic-key-poc-extensions" -Recurse -Force
```

Ne supprimez pas votre profil VS Code principal. Ne lancez pas
`docker compose down --volumes` comme arret normal : cela efface les cles
et les poids de cette stack.

## 12. Ce qu'il faut transmettre a un autre utilisateur

Transmettez le **depot et ce guide**, pas votre environnement local. Le code
necessaire est dans `extension`, `broker` et `scripts` de ce dossier ; le
Compose, la configuration LiteLLM et le modele de reference sont a la racine.
Un clone complet suffit a retrouver ces chemins.

Ne transmettez ni `.env`, ni cle utilisateur, ni jeton du broker, ni profil
VS Code, ni capture ou log contenant des secrets. Chaque poste de POC doit
creer sa propre stack et ses propres secrets, ou utiliser une architecture
de service geree adaptee comme decrit a l'etape 8.

## References

- [API Language Model Chat Provider](https://code.visualstudio.com/api/extension-guides/ai/language-model-chat-provider)
- [Modeles et exigences des parcours VS Code](https://code.visualstudio.com/docs/agent-customization/language-models)
- [Cles virtuelles LiteLLM](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [Installation manuelle sans extension](../vscode/README.md)
- [Stack locale LiteLLM et Ollama](../README.md)

Contenu prepare avec assistance IA ; relire et refaire les validations sur
le poste cible avant de presenter ce POC comme un parcours complet ou une
solution d'entreprise.
