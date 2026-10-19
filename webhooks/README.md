---
title: "GitHub : webhooks globaux et scenario de demonstration"
description: "Choisir le bon perimetre de webhook, distinguer Enterprise Cloud et Server et preparer une demonstration sans donnees de production."
---

## Reponse courte

Oui, un proprietaire d'entreprise peut configurer un webhook global pour recevoir
certains evenements de son entreprise, de ses organisations et de leurs depots.
Il n'est alors pas necessaire de creer un webhook dans chaque depot pour ces
evenements. La liste disponible depend du produit, de sa version et du type
de webhook : global ne signifie pas tous les evenements GitHub.

Sur GitHub Enterprise Cloud, la configuration documentee passe par
**Enterprise settings > Hooks**. Sur GitHub Enterprise Server, une API
`/admin/hooks` existe aussi. Ne transposez pas cette API Server sur GitHub.com.

## Ce qu'il est pertinent de montrer

| Scenario                        | Preuves a montrer                                      | Acces necessaire                         |
|---------------------------------|--------------------------------------------------------|------------------------------------------|
| Webhook de depot, prise en main  | Un `ping`, sa livraison et la reponse du recepteur        | Administration d'un depot de test         |
| Webhook global, demo du sujet   | Un seul hook et des evenements de deux depots de test    | Proprietaire d'une entreprise de test     |
| Monitoring CI                   | Un evenement `workflow_run` apres un workflow de test    | Evenement disponible et Actions configure |

Pour expliquer le principe, une demo de depot de cinq minutes suffit.
Pour prouver le caractere global, il faut une entreprise de test avec deux depots :
un webhook de depot ne prouve pas la couverture entreprise.
Cette demo ne depend ni de LiteLLM ni de Grafana ; aucun nouveau conteneur
n'est necessaire si un recepteur HTTPS approuve existe deja.

> [!NOTE]
> Ce dossier fournit un recepteur local executable et les scripts de gestion.
> Aucun webhook global, tunnel reseau ou abonnement a des evenements n'a ete cree.
> Les tests locaux sont synthetiques ; une livraison depuis GitHub exige les
> acces requis et une URL HTTPS approuvee.

## Demarrer avec les scripts

Depuis la racine du depot, avec PowerShell 7.4 et Python 3.11 ou plus recent :

```powershell
# Terminal 1 : genere le secret ignore puis garde le recepteur au premier plan.
.\webhooks\start-receiver.ps1
```

Dans un deuxieme terminal, toujours depuis la racine :

```powershell
# Trois verifications sur le vrai recepteur HTTP local, sans appel a GitHub.
.\webhooks\test-demo.ps1
Start-Process 'http://127.0.0.1:8787'
```

Resultats attendus : evenement signe accepte en `202`, doublon reconnu en `200`
sans nouvel enregistrement, corps altere refuse en `401` et non conserve.
Le navigateur affiche les metadonnees des livraisons valides ; aucun payload
complet ni secret n'est affiche. Un test local ne prouve pas la reception GitHub.
Pour changer de port, utiliser le meme `-Port` dans les deux scripts.
Arreter le recepteur avec **Ctrl+C** dans son terminal.

Le recepteur ecoute uniquement sur `127.0.0.1`. Il conserve au plus 1000 livraisons
en memoire, perdues au redemarrage ; le dedoublonnage est limite a cette fenetre.
Il refuse les corps de plus de 1 Mio, contrairement au plafond GitHub qui peut
etre superieur : ce serveur de demonstration n'est pas un collecteur de production.
Il ne traite aucune action metier. Un reverse proxy approuve doit exposer
uniquement `/webhook`, pas le dashboard ni `/deliveries`.

### Creer et tester un vrai hook de depot ou d'organisation

Faire fournir une URL HTTPS approuvee qui relaie **les octets bruts et les headers**
vers `http://127.0.0.1:8787/webhook`. Ce depot n'ouvre aucun tunnel et ne deploie
aucun hebergement automatiquement. Verifier l'authentification avec `gh auth status`
avant de choisir une cible ; les scripts ne changent jamais de compte.
Enlever `GH_DEBUG` si present pour ne pas journaliser les secrets.

```powershell
$repo = Read-Host 'Depot de test approuve (OWNER/REPO)'
$receiverUrl = Read-Host 'URL HTTPS approuvee, chemin /webhook inclus'

# Previsualiser sans appel API ni creation.
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Create `
    -PayloadUrl $receiverUrl -Events repository -WhatIf

# Confirmation interactive ; le secret local est transmis via stdin, pas en argument.
$hook = .\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Create `
    -PayloadUrl $receiverUrl -Events repository
$hook

# Garder cet ID : ne jamais supprimer tous les hooks du depot.
if (-not $hook.id) { throw 'Creation non effectuee : pas de hook a tester.' }
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Ping -HookId $hook.id
Start-Sleep -Seconds 3
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Deliveries -HookId $hook.id
```

Verifier dans les livraisons GitHub une reponse `202`, puis le `ping` avec
`signature_verified: true` dans le dashboard local. Une demande de ping acceptee
par l'API ne signifie pas que sa livraison est reussie ; si elle est encore
en cours, relancer seulement `Deliveries`. Les dix dernieres livraisons sont affichees.
Pour une organisation, remplacer `Repository` par `Organization` et `$repo`
par le slug de l'organisation ; le compte doit etre owner.
`List` affiche les hooks existants, sans leurs URLs ni secrets :

```powershell
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action List
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Delete -HookId $hook.id -WhatIf
# A la fin : supprimer uniquement le hook de cette demo, avec confirmation.
.\webhooks\manage-hook.ps1 -Scope Repository -Target $repo -Action Delete -HookId $hook.id
```

### Hooks globaux

Cloud ne fournit pas ici la meme API de creation que Server. Le script ouvre
la page de configuration Cloud ; le proprietaire d'entreprise remplit le
formulaire comme decrit plus bas. Le secret genere est dans `webhooks\.env` :
le copier hors partage d'ecran et ne jamais le committer.

```powershell
$enterprise = Read-Host 'Slug de l entreprise de test'
.\webhooks\manage-hook.ps1 -Scope CloudEnterprise -Target $enterprise -Action OpenSettings
```

Pour GHES, les commandes `List`, `Create`, `Ping` et `Delete` utilisent
`/admin/hooks` sur l'hote explicite. Il faut un site admin et un PAT classic.
La cible est l'instance GHES, pas seulement une organisation. Par exemple :

```powershell
$server = Read-Host 'Nom DNS du serveur GHES de test, sans https'
.\webhooks\manage-hook.ps1 -Scope ServerEnterprise -GitHubHostname $server `
    -Target $enterprise -Action List
```

Les actions qui modifient GitHub demandent confirmation et supportent `-WhatIf`.
Ne pas ajouter `-Confirm:$false` en presentation sauf automatisation deja approuvee.
Sur Server, consulter les livraisons via `-Action OpenSettings`.

### Verifications locales reproductibles

```powershell
python -m unittest discover -s webhooks -p test_receiver.py -v
.\scripts\test-github-demos.ps1
```

Le second script simule `gh` pour verifier les routes, erreurs, sorties filtrees
et `-WhatIf` ; il ne prouve pas les permissions d'une entreprise reelle.

## 1. Choisir Cloud, Server et le bon perimetre

| Perimetre       | Portee                                                | Point d'attention                              |
|-----------------|-------------------------------------------------------|------------------------------------------------|
| Depot           | Evenements du depot                                   | Administration du depot necessaire             |
| Organisation    | Evenements de l'organisation et de ses depots          | Proprietaire de l'organisation                 |
| Entreprise      | Evenements disponibles au niveau entreprise           | Proprietaire de l'entreprise                   |
| GitHub App      | Evenements accordes a l'app sur ses installations      | Permissions et perimetre d'installation limites |

Une GitHub App installee sur une entreprise ne recoit pas actuellement de
webhooks a ce niveau selon la documentation des types de webhooks.
Pour recevoir ses evenements d'organisation/depot, elle doit etre installee
dans les organisations concernees. Ne confondez pas possession d'une app par
l'entreprise, installation au niveau entreprise et webhook global.

Sur Cloud, `business` dans le catalogue des evenements designe le perimetre
entreprise. Exemples verifies dans le catalogue officiel :

| Evenement       | Global Cloud disponible | Usage                                           |
|-----------------|-------------------------|-------------------------------------------------|
| `repository`    | Oui                     | Creation et changements du cycle de vie du depot |
| `organization`  | Oui                     | Activite de l'organisation et de ses membres     |
| `team`          | Oui                     | Activite des equipes                             |
| `membership`    | Oui                     | Changements d'appartenance aux equipes           |
| `workflow_run`  | Oui                     | Activite d'execution GitHub Actions               |
| `push`          | Non dans ce catalogue   | Utiliser un hook de depot, organisation ou app    |

Cette table n'est pas exhaustive. Pour chaque evenement, verifier la rubrique
**Availability** dans le catalogue et les actions couvertes, puis le selecteur
de votre entreprise avant la presentation.

Pour Server, selectionner votre version dans la documentation. La page REST
des global webhooks de GHES 3.22 cite notamment `organization`, `user`,
`repository`, `team`, `member`, `membership`, `fork` et `ping`.
Les listes du catalogue d'evenements et de la page REST ne sont pas toujours
presentees de la meme maniere : ne deduisez pas la liste Server du tableau Cloud.
Ne presentez pas non plus `workflow_run` comme un evenement exclusivement Cloud.

## 2. Preparer une reception autorisee

Il faut une URL HTTPS joignable depuis GitHub, par exemple un recepteur de test
interne approuve par votre organisation. `http://localhost` sur votre poste
n'est pas joignable depuis GitHub Enterprise Cloud.

Le recepteur doit :

- Verifier `X-Hub-Signature-256` sur les octets bruts du corps avec le secret HMAC,
  avant toute action metier, avec une comparaison en temps constant
- Identifier l'evenement avec `X-GitHub-Event`
- Dedoublonner les traitements a partir de `X-GitHub-Delivery`
- Repondre rapidement en `2xx` et deleguer le traitement long a une file
- Journaliser uniquement les metadonnees utiles a la demo, pas les secrets
  ni l'ensemble des payloads de production

Le recepteur des scripts et son hook de demo doivent partager le secret genere
dans `webhooks\.env` : ne pas en generer un second pour ce meme recepteur.
Ce recepteur de demonstration utilise un seul secret ; pour une nouvelle demo
isolee, supprimer l'ancien hook puis regenerer le secret avant de redemarrer.

Pour un autre recepteur configure manuellement, utiliser un secret aleatoire
different pour chaque hook. Pour generer un secret ephemere dans PowerShell 7.4
et le copier sans l'afficher :

```powershell
$webhookSecret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
Set-Clipboard -Value $webhookSecret
```

Transmettre ce secret au recepteur via son gestionnaire de secrets et le coller
dans le champ **Secret** du webhook, hors partage d'ecran.
Le secret HMAC n'est pas un PAT et ne donne pas acces a l'API GitHub.
Conserver la verification TLS active. Ne pas utiliser de collecteur tiers
public ou de tunnel non approuve avec les payloads d'une entreprise.

## 3. Demo rapide sur un depot de test

1. Faire approuver le depot de test, son recepteur HTTPS et le secret.
2. Dans le depot, ouvrir **Settings > Webhooks > Add webhook**.
3. Renseigner la **Payload URL**, choisir `application/json` et renseigner le secret.
4. Selectionner seulement l'evenement utile, par exemple `workflow_run` si un
   workflow de test existe deja. Conserver **Active**, puis creer le webhook.
5. Ouvrir **Recent deliveries** : GitHub envoie un evenement `ping` a la creation
   du webhook de depot.
6. Verifier l'evenement, son identifiant de livraison et la reponse `2xx`.
7. Si Actions est configure, lancer manuellement un workflow inoffensif approuve,
   puis retrouver la livraison `workflow_run`, son action et sa conclusion.

Le `ping` prouve la connectivite et le traitement d'un evenement de test.
Il ne prouve ni le support d'un evenement metier ni le perimetre global.
Un `2xx` seul ne prouve pas la validation de signature : utiliser les logs
de validation du recepteur et un test negatif du recepteur avant la demo.

## 4. Demo globale sur une entreprise de test

1. Confirmer le produit, la version, le role de proprietaire et deux depots de test.
2. Pour Cloud, ouvrir l'entreprise, puis **Settings > Hooks > Add webhook**.
3. Configurer le recepteur approuve, `application/json`, le secret et **Active**.
4. Selectionner `repository` ou `workflow_run` selon le scenario retenu et
   les evenements effectivement disponibles. Ne pas selectionner tout par defaut.
5. Pour `workflow_run`, lancer un workflow de test dans le premier depot,
   puis dans le second. Pour `repository`, utiliser une operation approuvee,
   comme renommer un depot de test puis restaurer son nom, en anticipant
   l'impact sur les integrations qui utilisent son URL.
6. Dans les livraisons du meme hook global, montrer deux identifiants de livraison
   distincts et les deux depots sources. Verifier la reponse du recepteur.
7. Expliquer qu'aucun hook de depot supplementaire n'a ete cree pour ce scenario.

Sur Server, utiliser **Enterprise settings > Settings > Hooks** et la
documentation de votre version. L'API `/admin/hooks` est reservee aux
administrateurs de site et sa documentation impose un PAT classic.
Une GitHub App ou un compte organisation owner n'equivaut pas a site admin.

Les livraisons recentes ne sont pas une archive durable : le guide Cloud
indique trois jours, et le guide GHES 3.22 sept jours. Verifier la retention
de votre produit et stocker les preuves autorisees dans votre propre systeme.

## 5. Ce que les webhooks ne remplacent pas

Les webhooks ne remplacent pas le journal d'audit pour un historique de securite,
ni les API Copilot pour les licences et les metriques d'usage,
ni OpenTelemetry pour le detail des interactions du client.
Ils notifient des evenements disponibles a un recepteur ; un controle reactif
ne bloque pas automatiquement l'action qui a deja eu lieu.

Ne supposez ni ordre strict de livraison ni traitement exactement une fois.
La documentation indique que GitHub ne relivre pas automatiquement les
livraisons echouees : prevoir supervision et relivraison adaptees au type
de hook. Eviter qu'une action de votre recepteur ne cree une boucle d'evenements.

## 6. Fin de demonstration

1. Desactiver ou supprimer seulement le hook cree pour la demo, dans son interface.
2. Restaurer les modifications des depots de test avec l'accord de leur proprietaire.
3. Supprimer les payloads de test selon la retention convenue et revoquer le secret.
4. Vider le presse-papiers et la variable locale.

```powershell
Set-Clipboard -Value ''
Remove-Variable webhookSecret -ErrorAction SilentlyContinue
```

## Sources officielles

Documentation verifiee le 19 octobre 2026. Scenarios non executes sur une
entreprise cliente. Contenu prepare avec assistance IA, a relire avant diffusion.

- [Cloud : gestion des webhooks globaux](https://docs.github.com/en/enterprise-cloud@latest/admin/monitoring-activity-in-your-enterprise/exploring-user-activity-in-your-enterprise/managing-global-webhooks)
- [Cloud : types et perimetres des webhooks](https://docs.github.com/en/enterprise-cloud@latest/webhooks/types-of-webhooks)
- [Cloud : creation d'un webhook](https://docs.github.com/en/enterprise-cloud@latest/webhooks/using-webhooks/creating-webhooks)
- [Cloud : evenements, actions et disponibilite](https://docs.github.com/en/enterprise-cloud@latest/webhooks/webhook-events-and-payloads)
- [Validation des signatures de livraison](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries)
- [Gestion des livraisons echouees](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries)
- [Server 3.22 : gestion des webhooks globaux](https://docs.github.com/en/enterprise-server@3.22/admin/monitoring-activity-in-your-enterprise/exploring-user-activity-in-your-enterprise/managing-global-webhooks)
- [Server 3.22 : API des webhooks globaux](https://docs.github.com/en/enterprise-server@3.22/rest/enterprise-admin/global-webhooks)
