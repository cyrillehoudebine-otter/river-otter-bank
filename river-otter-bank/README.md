# River Otter Bank

Tirelire virtuelle de Martí et Adrià. La page est hébergée gratuitement sur GitHub Pages, et les données, le code parent et les versements automatiques sont gérés gratuitement par Supabase.

Contenu du dossier :

| Fichier | Rôle |
|---|---|
| `index.html` | L'appli (une seule page) |
| `manifest.webmanifest`, `icon-*.png`, `apple-touch-icon.png` | Icône et installation sur l'écran d'accueil |
| `supabase.sql` | Script de la base de données (à coller dans Supabase) |
| `.github/workflows/keepalive.yml` | Réveille la base tous les 3 jours |

---

## 1. Créer la base Supabase (10 min)

1. Créez un compte sur https://supabase.com (connexion possible avec le compte GitHub).
2. **New project** : nom `river-otter-bank`, région **West EU (Paris)**, choisissez un mot de passe de base de données et notez-le (il ne sert pas à l'appli).
3. Une fois le projet prêt, ouvrez **SQL Editor** → **New query**, collez **tout** le contenu de `supabase.sql`, puis **Run**. Le résultat doit se terminer sans erreur.
4. Ouvrez **Project Settings** → **API Keys** et notez :
   - l'**URL du projet** (de la forme `https://abcdefgh.supabase.co`, visible aussi dans **Project Settings → Data API**) ;
   - la **Publishable key** (commence par `sb_publishable_`). Si seules les anciennes clés sont proposées, prenez la clé **anon public**.

   N'utilisez jamais la clé **secret** ou **service_role** dans l'appli.

## 2. Renseigner l'appli

Ouvrez `index.html` dans un éditeur de texte et remplacez les deux valeurs en haut du script :

```js
const CONFIG = {
  url: 'https://VOTRE-PROJET.supabase.co',
  key: 'VOTRE_CLE_PUBLISHABLE'
};
```

## 3. Mettre en ligne sur GitHub Pages (5 min)

1. Créez un compte sur https://github.com.
2. **New repository** : nom `river-otter-bank`, visibilité **Public** (nécessaire pour Pages gratuit), puis **Create repository**.
3. Cliquez sur **uploading an existing file** et glissez-déposez **tout le contenu du dossier**, y compris le dossier `.github`. Sur Mac, les dossiers commençant par un point sont masqués : appuyez sur Cmd + Maj + point dans le Finder pour les afficher. Validez avec **Commit changes**.
4. **Settings** → **Pages** → Source : **Deploy from a branch**, branche **main**, dossier **/ (root)** → **Save**.
5. Au bout d'une minute, l'appli est en ligne à l'adresse `https://VOTRE-PSEUDO.github.io/river-otter-bank/`.

## 4. Installer sur les téléphones

- **iPhone (Safari)** : ouvrez l'adresse → bouton Partager → **Sur l'écran d'accueil**.
- **Android (Chrome)** : ouvrez l'adresse → menu ⋮ → **Installer l'application** ou **Ajouter à l'écran d'accueil**.

## 5. Première utilisation

1. Le code parent de départ est **0000**. Changez-le tout de suite : **GUIDE** → code `0000` → **CODE PARENT : CHANGER**.
2. Faites le **dépôt initial** de chaque enfant avec le bouton **+ DÉPÔT**.
3. Dans **GUIDE**, réglez l'argent de poche de chacun (montant, chaque semaine ou chaque mois, jour, date de départ) puis **ENVOI**.

---

## Fonctionnement

- **Sécurité** : la page ne peut rien écrire directement dans la base. Chaque dépôt, retrait ou réglage passe par une fonction côté serveur qui vérifie le code parent. Le code est stocké haché, jamais en clair. Après 3 codes faux, l'accès est bloqué 15 minutes. Modifier les fichiers de l'appli ne permet donc pas de tricher. La clé publishable est visible dans `index.html`, c'est normal : elle ne donne accès qu'à ces fonctions.
- **Argent de poche** : la base vérifie toutes les 10 minutes s'il y a un versement à faire (à 00h01, heure de Paris). Si la base a été en pause, les versements manqués sont rattrapés à leur date au prochain accès. Un même versement n'est jamais fait deux fois.
- **Réglages** : un changement s'applique à partir de la date choisie (aujourd'hui ou plus tard) et ne modifie jamais les versements passés.
- **Montants** : jusqu'à 9999,99 € par tirelire. Un retrait ne peut pas dépasser le solde.
- **Erreur de saisie** : une opération ne peut pas être supprimée. Pour la corriger, faites l'opération inverse (par exemple un retrait pour annuler un dépôt en trop).

## Plan gratuit Supabase

Un projet gratuit est mis en pause après 7 jours sans activité. Le fichier `keepalive.yml` appelle la base tous les 3 jours pour l'éviter. Deux points à surveiller :

- GitHub désactive les tâches planifiées d'un dépôt public après 60 jours sans modification du dépôt. Vous recevez alors un e-mail, et un clic dans l'onglet **Actions** suffit à les réactiver.
- Si le projet est malgré tout mis en pause, rouvrez-le depuis le tableau de bord Supabase (**Restore project**). Aucune donnée n'est perdue et les versements manqués sont rattrapés.

Pour lancer la tâche à la main et vérifier qu'elle fonctionne : onglet **Actions** → **keepalive** → **Run workflow**.
