# Scenario fonctionnel de migration

Ce document simule une migration SharePoint complete avec le mode projet.
Il explique les commandes a executer, leur objectif fonctionnel et le resultat attendu a chaque etape.

Le scenario utilise le projet d'exemple `Migration-Lunii`.

## Objectif du scenario

Migrer un dossier local vers une bibliotheque SharePoint en gardant:

- un inventaire persistant dans une base SQLite `.db`;
- la possibilite de reprendre apres un crash;
- un suivi des fichiers en erreur;
- un controle des fichiers modifies pendant la migration;
- des rapports CSV exploitables en fin de traitement.

## Hypotheses de depart

Le fichier `config.xml` contient deja:

- les informations d'authentification Entra ID;
- le chemin local source;
- le site SharePoint cible;
- la bibliotheque cible;
- les limites d'erreur;
- le mode de hash.

Exemple de configuration fonctionnelle:

```xml
<Migration>
    <HashMode>SHA256</HashMode>
    <MaxAttemptsPerFile>3</MaxAttemptsPerFile>
    <MaxTotalErrors>1000</MaxTotalErrors>
    <ParallelUploads>4</ParallelUploads>
    <AssumeDestinationEmpty>false</AssumeDestinationEmpty>
    <ProcessingBatchSize>1000</ProcessingBatchSize>
</Migration>
```

Dans ce scenario:

- `SHA256` permet de detecter les modifications reelles du contenu;
- `MaxAttemptsPerFile` evite de retenter indefiniment le meme fichier;
- `MaxTotalErrors` arrete la migration si trop d'erreurs apparaissent pendant une execution.
- `ParallelUploads` execute plusieurs uploads simultanement;
- `AssumeDestinationEmpty` controle si l'existence distante est verifiee avant chaque upload;
- `ProcessingBatchSize` limite la memoire utilisee pour lire la base SQLite.

## Etape 1 - Afficher l'aide

Commande:

```powershell
.\main.ps1 -Help
```

Objectif:

Verifier les commandes disponibles avant de lancer une migration.

Resultat attendu:

Le script affiche les modes principaux:

- creation de projet;
- inventaire;
- delta inventaire;
- controle des changements;
- migration;
- reprise;
- statut;
- export de rapports;
- purge des anciens rapports;
- reinitialisation des erreurs.

## Etape 2 - Creer le projet

Commande:

```powershell
.\main.ps1 -NewProject -ProjectName "Migration-Lunii" -ConfigPath .\config.xml
```

Objectif:

Creer un espace de travail dedie a la migration.

Resultat attendu:

Le script cree:

```text
projects/
`-- Migration-Lunii/
    |-- project.json
    |-- config.xml
    |-- migration.db
    |-- logs/
    `-- reports/
```

La base `migration.db` devient la reference de suivi du projet.

Point important:

Apres creation du projet, les prochaines modifications de configuration doivent etre faites dans:

```text
projects/Migration-Lunii/config.xml
```

## Etape 3 - Generer l'inventaire initial

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Inventory
```

Objectif:

Analyser tous les fichiers locaux avant migration et alimenter la base de donnees.

Ce que fait le script:

- lit le dossier source;
- applique les exclusions;
- calcule le hash selon `Migration.HashMode`;
- recupere les extensions bloquees du tenant SharePoint;
- inscrit les fichiers dans la table `Files`;
- positionne les statuts initiaux.

Statuts possibles apres inventaire:

- `Pending`: fichier pret a migrer;
- `BlockedExtension`: fichier non migrable a cause d'une extension bloquee;
- `MissingLocalFile`: fichier connu en base mais absent localement, dans certains cas de relance;
- `Uploaded` ou `SkippedExists`: statuts conserves si la base contenait deja ces fichiers et que leur hash n'a pas change.

Resultat attendu:

La base contient un etat initial fiable avant upload.

## Etape 4 - Controler le statut

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Status
```

Objectif:

Connaitre le volume a traiter avant de lancer la migration.

Resultat attendu:

Le script affiche un resume par statut, par exemple:

```text
Pending: 2900
BlockedExtension: 125
Total: 3025
```

Decision fonctionnelle:

- si le nombre de `BlockedExtension` est anormal, corriger la source ou les exclusions avant de continuer;
- si le volume `Pending` est coherent, lancer la migration.

Exemple de fichier bloque a la source:

Un utilisateur a dans le dossier source un fichier:

```text
C:\Donnees\Lunii\Archives\ancien-outil.exe
```

Si l'extension `.exe` est bloquee par le tenant SharePoint, l'inventaire le classe en:

```text
Status = BlockedExtension
```

Ce fichier ne sera pas envoye pendant `-Migrate`.

Pour l'analyser, exporter les rapports:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Puis ouvrir:

```text
projects/Migration-Lunii/reports/migration_report_yyyyMMdd_HHmmss.csv
```

Filtrer ensuite:

```text
Status = BlockedExtension
```

Decisions possibles:

- retirer le fichier du perimetre de migration;
- renommer ou convertir le fichier si le metier le valide;
- ajouter une exclusion si ce type de fichier ne doit jamais etre migre;
- modifier la politique SharePoint uniquement si c'est autorise par l'organisation.

Exemple d'exclusion dans `projects/Migration-Lunii/config.xml`:

```xml
<Exclusions>
    <Files>
        <Pattern>*.exe</Pattern>
    </Files>
</Exclusions>
```

Apres correction, relancer l'inventaire:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Inventory
.\main.ps1 -Project "Migration-Lunii" -Status
```

## Etape 5 - Lancer la migration

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Objectif:

Envoyer vers SharePoint les fichiers au statut `Pending`.

Ce que fait le script:

- lit les fichiers `Pending`;
- ignore les fichiers ayant atteint `MaxAttemptsPerFile`;
- cree les dossiers SharePoint manquants;
- verifie si le fichier existe deja;
- envoie le fichier si necessaire;
- met a jour le statut en base.

Statuts possibles apres migration:

- `Uploaded`: fichier envoye;
- `SkippedExists`: fichier deja present dans SharePoint et non ecrase;
- `Failed`: erreur pendant l'upload;
- `MissingLocalFile`: fichier absent du disque au moment de migrer.

Arret automatique:

Si le nombre d'erreurs de l'execution atteint `MaxTotalErrors`, la migration s'arrete.
La base conserve les statuts deja connus pour permettre une reprise.

## Etape 6 - Reprendre apres crash ou interruption

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Resume
```

Objectif:

Reprendre la migration sans repartir de zero.

Ce que fait le script:

- reprend les fichiers `Pending`;
- reprend aussi les fichiers `Failed`, si leur nombre de tentatives le permet;
- conserve les fichiers restes en `Uploading` et force leur verification distante;
- conserve les fichiers deja `Uploaded` ou `SkippedExists`.

Resultat attendu:

La migration continue la ou elle s'etait arretee.

## Etape 7 - Exporter les rapports

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Objectif:

Produire des fichiers CSV pour analyse ou transmission.

Rapports generes:

- `migration_report_yyyyMMdd_HHmmss.csv`: detail complet de la table `Files`;
- `migration_summary_yyyyMMdd_HHmmss.csv`: resume par statut;
- `migration_errors_yyyyMMdd_HHmmss.csv`: uniquement les fichiers `Failed` et `MissingLocalFile`;
- `migration_changes_yyyyMMdd_HHmmss.csv`: fichiers dont le hash a change lors du dernier inventaire ou delta.

Decision fonctionnelle:

- utiliser `migration_errors_*.csv` pour traiter les erreurs;
- utiliser `migration_summary_*.csv` pour valider l'avancement global;
- utiliser `migration_report_*.csv` pour auditer fichier par fichier.

## Etape 8 - Corriger les erreurs puis relancer

Exemple:

Un fichier est en `Failed` parce qu'il etait verrouille localement ou parce qu'un probleme reseau est survenu.

Exemple concret:

```text
C:\Donnees\Lunii\Comptabilite\budget-2026.xlsx
```

Pendant la migration, le fichier est ouvert ou verrouille. Le script tente l'upload, echoue, puis enregistre:

```text
Status = Failed
AttemptCount = 1
LastError = message technique de l'erreur
```

Exporter les rapports pour identifier les fichiers en erreur:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Ouvrir ensuite:

```text
projects/Migration-Lunii/reports/migration_errors_yyyyMMdd_HHmmss.csv
```

Ce rapport contient uniquement les fichiers:

- `Failed`;
- `MissingLocalFile`.

Correction fonctionnelle:

- fermer le fichier local;
- verifier que le fichier existe toujours;
- verifier que le chemin n'est pas trop long ou invalide cote SharePoint;
- corriger le probleme reseau ou d'autorisation si besoin.

Commande de reinitialisation:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ResetFailed
```

Objectif:

Remettre les fichiers `Failed` en `Pending` et remettre leur compteur de tentative a `0`.

Effet attendu en base:

```text
Status = Pending
AttemptCount = 0
LastError = vide
```

Puis relancer:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Resultat attendu:

Les fichiers corriges sont retentes proprement.

## Etape 9 - Verifier les changements pendant la migration

Pendant une migration longue, des utilisateurs peuvent modifier ou ajouter des fichiers dans le dossier source.
Il faut donc controler le delta avant de considerer la migration terminee.

Commande d'observation sans modifier les statuts:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
```

Objectif:

Voir ce qui a change localement sans preparer de nouvelle migration.

Resultat attendu:

Le script genere:

```text
projects/Migration-Lunii/reports/migration_checkchanges_yyyyMMdd_HHmmss.csv
```

Ce rapport peut contenir:

- `New`: fichier present localement mais absent de la base;
- `Modified`: fichier dont le hash local differe de celui stocke en base;
- `Deleted`: fichier absent localement, uniquement avec `-IncludeDeleted`.

Commande avec detection des suppressions:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges -IncludeDeleted
```

Decision fonctionnelle:

Si le rapport est vide, aucun changement local notable n'a ete detecte.
Si le rapport contient des fichiers, lancer un delta inventaire.

Point important:

`-CheckChanges` ne modifie pas la base. Il ne remet pas un fichier `Modified` en `Pending`.
Il sert uniquement a observer et a produire le rapport `migration_checkchanges_*.csv`.

Donc ce workflow est incomplet:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Dans ce cas, le fichier modifie peut ressortir au prochain `-CheckChanges`, car le hash de reference stocke en base n'a pas ete actualise.

Le workflow correct est:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
.\main.ps1 -Project "Migration-Lunii" -Migrate
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
```

## Etape 10 - Integrer les changements detectes

Commande standard:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
```

Objectif:

Mettre a jour la base avec les fichiers nouveaux ou modifies depuis le dernier inventaire.

Comportement:

- les nouveaux fichiers sont ajoutes en `Pending`;
- les fichiers modifies sont remis en `Pending` s'ils etaient deja `Uploaded` ou `SkippedExists`;
- les fichiers inchanges restent dans leur statut;
- les fichiers supprimes sont ignores par defaut.

Commande avec prise en compte des suppressions:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory -IncludeDeleted
```

Avec `-IncludeDeleted`, les fichiers absents localement sont marques `MissingLocalFile`.

Pour etre iso avec la source locale, supprimer aussi les fichiers correspondants dans SharePoint pendant la migration:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
```

Exemple:

Le fichier suivant existait dans l'inventaire et avait deja ete migre:

```text
C:\Donnees\Lunii\Archives\ancien-budget.xlsx
```

Il est ensuite supprime du dossier source local. Le delta avec suppressions le marque:

```text
Status = MissingLocalFile
```

Au prochain `-Migrate -DeleteRemoteMissing`, le script supprime la cible SharePoint associee, puis marque la ligne en base:

```text
Status = DeletedRemote
```

Sans `-DeleteRemoteMissing`, le fichier reste present dans SharePoint. C'est volontaire pour eviter une suppression distante accidentelle.

Pour migrer uniquement les ajouts et modifications sans supprimer les fichiers distants:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Resultat attendu:

Les fichiers ajoutes ou modifies pendant la migration sont traites.

## Etape 11 - Controle final

Commandes:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Status
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Objectif:

Valider que la migration est terminee et documentee.

Controle attendu:

- pas ou peu de fichiers `Pending`;
- pas de fichiers `Failed` non expliques;
- pas de changements detectes par `-CheckChanges`;
- rapports CSV disponibles dans `projects/Migration-Lunii/reports/`.

## Etape 12 - Purger les anciens rapports

Commande:

```powershell
.\main.ps1 -Project "Migration-Lunii" -PurgeReports -ReportRetentionDays 30
```

Objectif:

Nettoyer les anciens CSV de rapport en conservant les plus recents.

Resultat attendu:

Les rapports de plus de 30 jours sont supprimes du dossier `reports/`.

## Scenario resume

Pour une migration standard:

```powershell
.\main.ps1 -Help
.\main.ps1 -NewProject -ProjectName "Migration-Lunii" -ConfigPath .\config.xml
.\main.ps1 -Project "Migration-Lunii" -Inventory
.\main.ps1 -Project "Migration-Lunii" -Status
.\main.ps1 -Project "Migration-Lunii" -Migrate
.\main.ps1 -Project "Migration-Lunii" -Resume
.\main.ps1 -Project "Migration-Lunii" -ExportReport
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory -IncludeDeleted
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
.\main.ps1 -Project "Migration-Lunii" -Status
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

## Lecture fonctionnelle des commandes

| Commande | Role |
| --- | --- |
| `-Help` | Comprendre les options disponibles. |
| `-NewProject` | Creer le dossier projet, la configuration projet et la base SQLite. |
| `-Inventory` | Construire ou rafraichir l'inventaire complet en base. |
| `-Status` | Lire l'etat courant de la migration. |
| `-Migrate` | Migrer les fichiers eligibles. |
| `-Resume` | Reprendre apres interruption, avec gestion des fichiers en erreur. |
| `-ExportReport` | Produire les CSV de suivi. |
| `-CheckChanges` | Observer les changements locaux sans modifier les statuts. |
| `-DeltaInventory` | Integrer les fichiers nouveaux ou modifies dans la base. |
| `-IncludeDeleted` | Inclure les fichiers supprimes dans `-CheckChanges` ou `-DeltaInventory`. |
| `-DeleteRemoteMissing` | Supprimer dans SharePoint les fichiers marques `MissingLocalFile`. |
| `-ResetFailed` | Remettre les erreurs en attente pour les rejouer. |
| `-PurgeReports` | Nettoyer les anciens rapports. |

## Regle de decision finale

La migration peut etre consideree comme terminee quand:

- `-Status` ne montre plus de fichiers `Pending` a migrer;
- les fichiers `Failed` restants sont expliques ou exclus du perimetre;
- `-CheckChanges` ne remonte plus de fichiers `New` ou `Modified`;
- les rapports finaux ont ete exportes et archives.
