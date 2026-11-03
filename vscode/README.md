---
title: "VS Code et LiteLLM : installation avec cle manuelle"
description: "Configurer Custom Endpoint, conserver la reference de secret VS Code, tester le Chat et remplacer une cle individuelle."
---

# VS Code et LiteLLM : parcours manuel

Ce parcours utilise le fournisseur **Custom Endpoint** de VS Code. Il ne
necessite pas l'extension maison ni le broker du depot. Une cle individuelle
LiteLLM est saisie une fois dans l'assistant ; son remplacement reste manuel.

Pour recuperer la cle automatiquement, utilisez plutot le
[POC extension + broker](../vscode-dynamic-key-poc/README.md). Les deux
parcours sont independants : ne creez pas un Custom Endpoint pour configurer
le fournisseur de cette extension.

## 1. Preparer un nouveau poste

Le chemin reproductible fourni ici cible Windows, PowerShell 7.4 ou plus
recent, Docker Desktop en mode Linux et VS Code avec le Chat disponible.
Copilot CLI, Node.js, Grafana et la GitHub Copilot app ne sont pas necessaires
pour ce parcours manuel.

Dans un terminal PowerShell :

```powershell
git clone https://github.com/Ch0wseth/copilot-litellm-demo.git
Set-Location .\copilot-litellm-demo
$PSVersionTable.PSVersion
docker info --format '{{.ServerVersion}}'
code --version
```

Si Docker Desktop utilise plusieurs contextes, selectionnez `desktop-linux`
pour ce terminal. Verifiez que les ports locaux 4000 et 11434 ne sont pas deja
occupes ; ne stoppez pas une autre passerelle pour lancer cette demo.

```powershell
$env:DOCKER_CONTEXT = 'desktop-linux'
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 4000, 11434 } |
    Select-Object LocalAddress, LocalPort, OwningProcess
.\scripts\start-demo.ps1
docker compose ps
docker compose exec -T ollama ollama list
```

Attendez `Demo ready` et verifiez la presence de `qwen3:4b-8k`. Le script
genere votre `.env` si necessaire et telecharge le modele. Ne copiez pas le
`.env` d'un autre poste et ne l'affichez pas : il contient les secrets
d'administration et PostgreSQL. Pour les details de la stack et des volumes,
consultez le [guide principal](../README.md).

Si vous utilisez un projet Compose nomme, definissez le meme
`COMPOSE_PROJECT_NAME` dans chaque terminal utilisant les scripts Docker.
Changer de nom isole les volumes, mais ne libere pas les ports deja occupes.

### Avec une passerelle LiteLLM deja fournie par votre administrateur

Vous n'avez pas a deployer Ollama/PostgreSQL sur votre poste. Obtenez une
**cle individuelle**, l'URL complete de Chat Completions, l'identifiant du
modele et ses budgets de tokens. Configurez ces valeurs dans VS Code a la
place des valeurs locales ci-dessous. Utilisez HTTPS pour une passerelle
distante et les autorisations approuvees par votre organisation.

N'executez pas `new-user-key.ps1` avec la master key d'une passerelle
d'entreprise sur le poste d'un utilisateur. Ce script est reserve a la
stack de demonstration que vous administrez vous-meme.

## 2. Creer et copier une cle individuelle

Pour votre stack locale uniquement, depuis la racine du depot :

```powershell
$vscodeKey = .\scripts\new-user-key.ps1 -Alias demo-vscode
Set-Clipboard -Value $vscodeKey
code .
```

L'affectation capture la cle au lieu de l'afficher. Ne tapez pas `$vscodeKey`
seul et ne l'inscrivez pas dans une commande ou un fichier. Chaque execution
du script cree une nouvelle cle limitee a `qwen3:4b-8k`, sans expiration
explicitement demandee par ce script. L'alias n'est pas une identite SSO.

Pour une cle deja fournie, utilisez plutot :

```powershell
$vscodeKey = Read-Host 'Cle individuelle LiteLLM' -MaskInput
Set-Clipboard -Value $vscodeKey
```

Le presse-papiers reste accessible aux autres applications et a certains
historiques de presse-papiers. Faites cette etape hors partage d'ecran.

## 3. Configurer Custom Endpoint

Dans la fenetre VS Code voulue :

1. Ouvrez le Chat puis la palette avec `Ctrl+Shift+P`.
2. Executez **Chat: Manage Language Models**.
3. Choisissez **Add Models**, puis **Custom Endpoint**.
4. Nommez le groupe `LiteLLM local`.
5. Collez la cle individuelle dans le champ de cle API. Ne collez jamais la master key.
6. Choisissez **Chat Completions**, pas Responses ni Messages.
7. Dans le fichier `chatLanguageModels.json` ouvert par cet assistant,
   completez la configuration a partir de [chatLanguageModels.json](chatLanguageModels.json).
8. Conservez exactement la reference `apiKey` creee par VS Code pour ce
   profil, et toutes les autres entrees de fournisseurs deja configurees.
9. Enregistrez, puis revenez au selecteur de modele du Chat.

Les valeurs de la demo sont :

| Champ | Valeur |
|-------|--------|
| Fournisseur | `customendpoint` |
| Type d'API | `chat-completions` |
| Modele envoye a LiteLLM | `qwen3:4b-8k` |
| URL complete | `http://127.0.0.1:4000/v1/chat/completions` |
| Tokens d'entree / sortie | `7680` / `512` |
| Nom affiche | `Qwen 3 4B via LiteLLM` |

Le `toolCalling: true` du fichier de reference est une declaration de
configuration ; le test de ce guide utilise **Ask**, sans outils. Il ne
valide pas une session Agent ou des appels d'outils.

### Ou est la cle ?

VS Code stocke la cle dans son stockage de secrets. Le JSON contient une
reference du type `${input:chat.lm.secret.<identifiant>}`, pas la cle elle-meme.
Le placeholder du fichier du depot ne designe aucun secret reel.

Ne remplacez pas la reference generee par une reference inventee, `${env:...}`
ou `${get_api_key.py}`. Le parcours documente ici n'execute pas de script
pour obtenir la cle. `COPILOT_PROVIDER_API_KEY_COMMAND` concerne Copilot CLI,
pas la configuration Custom Endpoint de VS Code.

Le fichier du depot est un exemple : le copier dans un workspace ne le rend
pas automatiquement actif. Utilisez le fichier ouvert par l'assistant de
votre profil VS Code.

Apres la saisie, videz le presse-papiers et la variable du terminal :

```powershell
Set-Clipboard -Value ''
Remove-Variable vscodeKey
```

Si votre systeme conserve un historique ou synchronise le presse-papiers,
supprimez aussi cette entree via son interface.

## 4. Verifier une vraie reponse dans le Chat

Dans un autre terminal a la racine du depot, avec le meme projet Compose :

```powershell
docker compose logs --tail 30 -f litellm
```

Dans le Chat VS Code :

1. Selectionnez explicitement **Qwen 3 4B via LiteLLM**, pas Auto.
2. Choisissez **Ask**, puis creez un nouveau chat sans pieces jointes.
3. Envoyez le prompt de test suivant.

```text
/no_think Reply with exactly VSCODE_VIA_LITELLM_OK and nothing else.
```

La validation demande **deux observations** : `VSCODE_VIA_LITELLM_OK`
affiche dans le Chat et une nouvelle requete `POST /v1/chat/completions`
avec HTTP `200` dans LiteLLM. Le parcours manuel a ete observe avec
VS Code 1.144.1 ; refaites-le sur votre version et votre compte.

Une reponse peut prendre plusieurs minutes sur CPU. `/no_think` peut etre
ignore selon le template et la version d'Ollama. Un HTTP `200` sans texte
dans le Chat ne suffit pas pour declarer ce test reussi.

Si l'interface demande une connexion ou l'activation du Chat, suivez
l'assistant officiel dans le navigateur. Les exigences dependent du
harness, du compte, du workspace et des politiques ; une cle LiteLLM
ne remplace pas une authentification GitHub exigee par le parcours choisi.
Ne contournez pas une politique BYOK desactivee par votre administrateur.

## 5. Remplacer, revoquer ou retirer la cle

Le fournisseur ne renouvelle pas la cle automatiquement.

Pour votre stack de test, creez une nouvelle cle avec un nouvel alias,
capturez-la et copiez-la comme a l'etape 2. Pour une passerelle geree, faites
fournir la nouvelle cle par son service autorise.

Dans **Chat: Manage Language Models**, ouvrez les options ou la roue dentee
du fournisseur **Custom Endpoint** pour modifier sa cle. Si votre version
ne propose pas cette action, reconfigurez ce fournisseur via l'assistant,
en preservant les autres fournisseurs. Gardez la nouvelle reference de
secret creee par VS Code, puis videz le presse-papiers.

Refaites le test de l'etape 4 avant de revoquer l'ancienne cle dans LiteLLM.
La procedure de [revocation locale](../README.md#8-montrer-la-revocation-dune-cle)
vise une cle precise, pas toutes les cles. Supprimer une entree de VS Code
ne revoque pas la cle cote LiteLLM, et revoquer une cle ne met pas a jour
le secret du profil VS Code.

## 6. Depannage et arret

| Symptome | Controle |
|----------|----------|
| Reference de secret inconnue | Refaire la saisie via l'assistant ; ne pas copier l'identifiant d'un autre profil |
| HTTP `401` | Cle individuelle expiree/revoquee, ou base recreee ; obtenir une nouvelle cle |
| Modele introuvable | Comparer l'identifiant avec `ollama list` et la configuration LiteLLM |
| HTTP `404` ou mauvaise API | Utiliser l'URL complete `/v1/chat/completions` et le type Chat Completions |
| Selecteur vide | Verifier l'activation du Chat, la confiance du workspace, le compte et les politiques |
| Modele present mais reponse lente | Nouveau chat Ask, prompt court, aucun fichier joint ; attendre le chargement du modele |
| Registre JSON sans effet | Modifier le fichier ouvert par Manage Language Models, pas simplement le fichier du depot |
| Changement de profil | Ressaisir la cle via l'assistant de ce profil ; ne pas inventer sa reference |

`Ctrl+C` dans le terminal de logs arrete seulement le suivi. Pour arreter
votre stack locale sans supprimer ses volumes :

```powershell
.\scripts\stop-demo.ps1
```

Les cles et poids persistent dans les volumes. Ne supprimez pas les volumes
ni le `.env` comme procedure d'arret normal.

## References

- [Modeles et Custom Endpoint dans VS Code](https://code.visualstudio.com/docs/agent-customization/language-models)
- [Cle dynamique : extension fournisseur et broker](../vscode-dynamic-key-poc/README.md)
- [Cle dynamique dans la CLI et le SDK](../copilot-app-dynamic-key/README.md)

Contenu prepare avec assistance IA ; verifier les politiques et les versions
de votre installation avant diffusion ou utilisation.
