---
title: "Cle dynamique BYOK : Copilot CLI, SDK et application"
description: "Reproduire localement les tests d'une commande de recuperation de cle API."
---

# Cle dynamique BYOK : Copilot CLI, SDK et application

## Objectif et limites

Pour VS Code, deux guides distincts sont disponibles :
[saisie manuelle dans Custom Endpoint](../vscode/README.md) et
[extension avec broker de cle dynamique](../vscode-dynamic-key-poc/README.md).
Le second contient le code, le demarrage sur un autre poste et les etapes
manuelles restantes dans le Chat. Les variables CLI/SDK de ce guide
ne configurent ni l'un ni l'autre de ces fournisseurs VS Code.

Reproduisez les essais d'une commande de recuperation de cle API avec
Copilot CLI et le SDK livre avec la GitHub Copilot app. Le test utilise un
serveur fictif local, une cle factice et une reponse predeterminee. Il ne
demarre ni LiteLLM ni un modele et ne transmet aucun prompt a un service distant.

Le test distingue trois configurations :

- La CLI utilise `COPILOT_PROVIDER_API_KEY_COMMAND`.
- Une session SDK BYOK utilise `provider.apiKeyCommand`.
- Un fournisseur nomme SDK, ajoute avec `providers` et `models`, est teste avec
  la variable CLI, puis avec un champ `apiKeyCommand` non pris en charge.

Un dernier essai avec une cle statique valide le fournisseur nomme et le
serveur fictif. Le test du champ non pris en charge est volontaire : ce champ
n'est pas declare dans `NamedProviderConfig` pour la version examinee.

> [!IMPORTANT]
> Le test ne pilote pas l'interface graphique de la GitHub Copilot app. Il
> charge le SDK fourni dans son installation, mais lance le runtime de la CLI
> installee separement. Il ne prouve donc pas si une app lancee depuis un
> terminal herite ou utilise la variable CLI, ni que tous les parcours ou
> toutes les versions de l'app utilisent la meme configuration SDK.

## Prerequis

- Windows, PowerShell et Node.js 22
- GitHub Copilot CLI installe avec un executable `copilot.exe`
- GitHub Copilot app installee, pour acceder au SDK de son installation
- Le depot clone localement

Les essais ci-dessous ont ete effectues le 3 novembre 2026 avec Node.js 22.23.4,
Copilot CLI 1.0.105 et GitHub Copilot app 1.1.34. Les fonctions BYOK de l'app
sont en public preview et peuvent evoluer.

Le chemin du SDK interne a l'app peut changer ; il n'est pas une API
d'installation garantie. Par defaut, le script cherche :

```text
%LOCALAPPDATA%\Programs\GitHub Copilot\copilot-sdk\index.js
```

Il cherche `copilot.exe` dans `PATH`. Si necessaire, indiquez les chemins
absolus avant de lancer le test :

```powershell
$env:COPILOT_APP_SDK_PATH = 'C:\chemin\copilot-sdk\index.js'
$env:COPILOT_CLI_PATH = 'C:\chemin\copilot.exe'
```

Le lanceur npm `copilot.cmd` n'est pas pris en charge par ce script.
Les variables ci-dessus ne sont necessaires que si les chemins par defaut
ne conviennent pas.

## 1. Lancer les tests isoles

Dans PowerShell, a la racine du depot :

```powershell
node --version
copilot --version
node .\copilot-app-dynamic-key\test-dynamic-key.mjs
```

Resultat attendu :

```text
PASS: CLI environment key command reached the local mock.
PASS: CLI key command read the test key from the process environment.
PASS: SDK session key command ran for each of two local model requests.
PASS: CLI environment key command was not used for the SDK named provider; the mock returned HTTP 401.
PASS: unsupported named-provider key command was not executed; the mock returned HTTP 401.
PASS: named provider with a static test key reached the local mock.
```

Les deux reponses `401` sont attendues : le serveur refuse une requete sans
la cle factice. Le script echoue si les resultats different, puis supprime
son dossier temporaire et arrete le serveur local.

Le serveur ecoute uniquement sur `127.0.0.1`, avec un port choisi par le
systeme. La CLI utilise `COPILOT_OFFLINE=true` et un repertoire Copilot
temporaire. Le test ne lit ni vos cles LiteLLM ni votre configuration de
fournisseurs. Il ne modifie pas les parametres de l'app.

## 2. Interpreter les resultats

La CLI a execute la commande definie par `COPILOT_PROVIDER_API_KEY_COMMAND`
et a transmis sa sortie au serveur local. La session SDK a execute
`provider.apiKeyCommand` avant chacune des deux requetes du test.

Pour le fournisseur nomme du SDK teste, ni la variable d'environnement CLI,
ni l'ajout du champ non pris en charge n'ont execute la commande. Le serveur
a refuse ces requetes. Avec une cle statique factice, le meme fournisseur
nomme a reussi. Ces observations concernent le SDK et le runtime testes,
pas une execution de l'interface graphique.

La documentation de l'app decrit l'ajout d'un fournisseur compatible OpenAI
et la saisie d'une cle, stockee dans le coffre de secrets du systeme. Elle
ne documente pas de champ pour une commande de recuperation de cle.
L'absence de documentation et le test SDK ne suffisent pas a conclure sur
toutes les possibilites de lancement de l'app.

## 3. Essayer la commande avec la stack LiteLLM du depot

Cette etape optionnelle utilise la vraie stack locale du depot. Elle n'est
pas executee par le test isole et doit etre validee sur votre installation.
Suivez d'abord les [prerequis et le demarrage de la demo](../README.md).

Dans un nouveau terminal PowerShell a la racine du depot, demarrez la stack
et creez une cle individuelle sans l'afficher :

```powershell
.\scripts\start-demo.ps1
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias dynamic-cli
```

Configurez ensuite la CLI pour le processus du terminal :

```powershell
Remove-Item Env:\COPILOT_PROVIDER_API_KEY, Env:\COPILOT_PROVIDER_BEARER_TOKEN -ErrorAction SilentlyContinue
$env:COPILOT_PROVIDER_BASE_URL = 'http://127.0.0.1:4000/v1'
$env:COPILOT_PROVIDER_TYPE = 'openai'
$env:COPILOT_PROVIDER_API_KEY_COMMAND = 'powershell.exe -NoProfile -Command "[Console]::Out.Write($env:LITELLM_USER_KEY)"'
$env:COPILOT_MODEL = 'qwen3:4b-8k'
$env:COPILOT_PROVIDER_MODEL_ID = 'gpt-4.1'
$env:COPILOT_PROVIDER_WIRE_MODEL = 'qwen3:4b-8k'
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = '7680'
$env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = '512'
$env:COPILOT_OFFLINE = 'true'
$env:COPILOT_PROVIDERS_CONFIG = Join-Path $env:TEMP ("copilot-empty-{0}.json" -f [guid]::NewGuid().ToString('N'))
```

Le chemin `COPILOT_PROVIDERS_CONFIG` unique ne designe aucun fichier
existant. Il evite qu'un registre `providers.json` deja configure prenne
priorite sur les variables de cette demonstration.

```powershell
copilot --context long_context --available-tools view --no-custom-instructions --disable-builtin-mcps --stream off --silent --prompt '/no_think Reply with exactly COPILOT_VIA_LITELLM_OK and nothing else. Do not use tools.'
```

La reponse attendue est `COPILOT_VIA_LITELLM_OK`. Verifiez aussi les logs
LiteLLM comme indique dans le [guide principal](../README.md). Ce parcours
utilise la CLI directement : `scripts\run-copilot-cli.ps1` configure une cle
statique et ne demontre pas la commande dynamique.

La commande relit ici une cle stockee dans l'environnement du processus.
Elle ne cree pas de nouvelle cle et ne fait pas de rotation automatique :
modifier la variable dans un autre terminal ne met pas a jour une CLI deja
lancee. Pour une vraie rotation, remplacez la commande par un mecanisme
autorise qui recupere la cle individuelle a chaque appel et n'ecrit que
cette cle sur sa sortie standard.

> [!WARNING]
> L'environnement d'un processus n'est pas un coffre de secrets. N'affichez
> pas `LITELLM_USER_KEY`, ne l'inscrivez pas dans un fichier versionne et
> n'utilisez jamais la master key comme cle de client. Ne lancez pas la
> generation de cles administrateur a chaque requete. Fermez le terminal
> dedie a la fin de la demonstration.

## Depannage

- SDK introuvable : verifiez le chemin de l'app et renseignez
  `COPILOT_APP_SDK_PATH`. Le SDK interne peut changer entre versions.
- CLI introuvable : verifiez `copilot --version` et renseignez
  `COPILOT_CLI_PATH` avec le chemin absolu vers `copilot.exe`.
- Resultat du test different : relevez les versions de Node.js, de la CLI et
  de l'app. Le comportement BYOK peut evoluer ; ne masquez pas un echec.
- HTTP `401` avec LiteLLM reel : verifiez la validite et les droits de la cle
  individuelle sans l'afficher. Les `401` du test isole sont, eux, attendus.
- Mauvais fournisseur CLI : verifiez `COPILOT_PROVIDERS_CONFIG` et les
  variables de fournisseur actives. Un registre non vide peut prendre priorite.

## References

- [Ajouter des modeles a la GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/add-llm-models)
- [Ajouter des modeles a Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-llm-models)
- [Authentification BYOK du Copilot SDK](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/byok)
- [Configuration de fournisseurs pour Copilot CLI](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference#providersjson)
