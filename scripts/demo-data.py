#!/usr/bin/env python3
# Remplit une instance de démonstration d'Organizer avec des données fictives, via son API locale.
# Usage : python3 scripts/demo-data.py <dossier ORGANIZER_DEMO_DIR>
import datetime as dt, json, os, sys, urllib.request

info = json.load(open(os.path.join(sys.argv[1], 'api.json')))
B, T = info['base_url'], info['token']

def call(method, path, body=None):
    req = urllib.request.Request(B + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + T, 'Content-Type': 'application/json'})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        sys.exit(f'{method} {path} -> {e.code} {e.read().decode()[:300]}')

today = dt.date.today()
def day(offset): return (today + dt.timedelta(days=offset)).isoformat()
def at(offset, hour, minute=0):
    return dt.datetime.combine(today + dt.timedelta(days=offset), dt.time(hour, minute)).astimezone().isoformat(timespec='seconds')

LUMEN, BOREE, PERSO, WAIT = 'Atelier Lumen', 'Studio Borée', 'Perso', '⏳ En attente'
for name in (LUMEN, BOREE, PERSO, WAIT):
    call('POST', '/labels', {'name': name})

projects = [
    ('Lumen · Boutique', '#4F7CFF', [LUMEN]), ('Lumen · Maintenance', '#30B0C7', [LUMEN]),
    ('Borée · App mobile', '#7B5CFF', [BOREE]), ('Administratif', '#FF9F0A', [PERSO]),
]
for name, color, labels in projects:
    call('POST', '/projects', {'name': name, 'color': color, 'labels': labels})

tasks = [
    # (titre, projet, facettes, statut, priorité, échéance, estimation, clé)
    ('Tunnel de commande : paiement en 3 fois', 'Lumen · Boutique', [LUMEN], 'in_progress', 3, 1, 240, 'WEB-41'),
    ('Fiche produit : galerie plein écran', 'Lumen · Boutique', [LUMEN], 'in_progress', 2, 3, 180, 'WEB-38'),
    ('Export comptable mensuel (CSV)', 'Lumen · Maintenance', [LUMEN], 'almost_done', 2, 0, 120, 'WEB-35'),
    ('Corriger le calcul des frais de port', 'Lumen · Maintenance', [LUMEN], 'todo', 3, 0, 60, 'WEB-44'),
    ('Recherche : filtres par couleur et matière', 'Lumen · Boutique', [LUMEN], 'todo', 1, 6, 300, 'WEB-45'),
    ('Notifications push : rappels de séance', 'Borée · App mobile', [BOREE], 'todo', 2, 2, 180, None),
    ('Écran profil : mode sombre', 'Borée · App mobile', [BOREE], 'in_progress', 1, 4, 120, None),
    ('Mise en ligne TestFlight 1.4', 'Borée · App mobile', [BOREE], 'almost_done', 2, 1, 45, None),
    ('Valider les maquettes de l\'onboarding', 'Borée · App mobile', [BOREE, WAIT], 'todo', 1, 5, 30, None),
    ('Accès au compte marchand', 'Lumen · Boutique', [LUMEN, WAIT], 'backlog', 2, None, 15, 'WEB-47'),
    ('Migration vers la nouvelle API de livraison', 'Lumen · Maintenance', [LUMEN], 'backlog', 2, 14, 480, 'WEB-48'),
    ('Tests de bout en bout du panier', 'Lumen · Boutique', [LUMEN], 'backlog', 1, None, 360, 'WEB-49'),
    ('Synchronisation hors ligne', 'Borée · App mobile', [BOREE], 'backlog', 2, 20, 600, None),
    ('Widget écran d\'accueil', 'Borée · App mobile', [BOREE], 'backlog', 1, None, 240, None),
    ('Déclaration de TVA du trimestre', 'Administratif', [PERSO], 'todo', 3, 2, 45, None),
    ('Renouveler l\'assurance professionnelle', 'Administratif', [PERSO], 'backlog', 1, 25, 20, None),
    ('Page panier : codes promo', 'Lumen · Boutique', [LUMEN], 'done', 2, -2, 180, 'WEB-33'),
    ('Connexion par lien magique', 'Borée · App mobile', [BOREE], 'done', 2, -3, 240, None),
    ('Optimiser les images du catalogue', 'Lumen · Maintenance', [LUMEN], 'done', 1, -5, 120, 'WEB-30'),
]
ids = {}
for title, project, labels, status, priority, due, estimate, key in tasks:
    body = {'title': title, 'project': project, 'labels': labels, 'status': status, 'priority': priority, 'estimate_minutes': estimate}
    if due is not None: body['due_date'] = day(due)
    if key: body['jira_key'] = key
    ids[title] = call('POST', '/tasks', body)['id']

entries = [
    # (jour, heure, minutes, tâche, description)
    (-4, 9, 150, 'Optimiser les images du catalogue', 'Compression et formats modernes'),
    (-4, 14, 180, 'Connexion par lien magique', 'Envoi du lien et expiration'),
    (-3, 9, 210, 'Page panier : codes promo', 'Règles de cumul'),
    (-3, 14, 120, 'Connexion par lien magique', 'Tests sur appareil'),
    (-2, 9, 240, 'Tunnel de commande : paiement en 3 fois', 'Intégration du prestataire'),
    (-2, 15, 90, 'Écran profil : mode sombre', 'Palette et contrastes'),
    (-1, 9, 180, 'Fiche produit : galerie plein écran', 'Zoom et gestes'),
    (-1, 13, 150, 'Export comptable mensuel (CSV)', 'Colonnes et arrondis'),
    (-1, 16, 75, 'Mise en ligne TestFlight 1.4', 'Notes de version'),
    (0, 9, 135, 'Tunnel de commande : paiement en 3 fois', 'Échéancier et récapitulatif'),
    (0, 11, 50, 'Export comptable mensuel (CSV)', 'Relecture'),
]
project_of = {t[0]: t[1] for t in tasks}
for offset, hour, minutes, title, description in entries:
    call('POST', '/time-entries', {'start': at(offset, hour, 15), 'duration_minutes': minutes, 'task_id': ids[title],
                                   'project': project_of[title], 'description': description, 'billable': True})

call('POST', '/notes', {'title': 'Point hebdo Atelier Lumen', 'labels': [LUMEN], 'pinned': True, 'body': """## Décisions
- Paiement en 3 fois : lancement prévu avec la collection d'automne
- La galerie plein écran passe avant les filtres de recherche

## À suivre
- [ ] Recevoir les accès au compte marchand
- [ ] Chiffrer la migration de l'API de livraison
- [x] Envoyer l'export comptable d'essai

> Prochain point : jeudi 10 h
"""})
call('POST', '/notes', {'title': 'Idées pour la 1.5', 'labels': [BOREE], 'body': """- Rappels de séance personnalisables
- Partage d'un programme par lien
- Statistiques sur 12 semaines

**Priorité** : la synchronisation hors ligne, demandée par la moitié des testeurs.
"""})
call('POST', '/notes', {'title': 'Checklist de mise en production', 'labels': [LUMEN, BOREE], 'body': """1. Sauvegarde de la base
2. Migrations jouées en préproduction
3. Vérification des tableaux de bord
4. Annonce dans le canal d'équipe
"""})

call('POST', '/artifacts', {'title': 'Parcours de commande — schéma', 'url': 'https://example.com/parcours-commande', 'kind': 'design',
                            'summary': 'Étapes du tunnel, états d\'erreur et points de reprise.', 'labels': [LUMEN], 'task_id': ids['Tunnel de commande : paiement en 3 fois']})
call('POST', '/artifacts', {'title': 'Comparatif des prestataires de paiement', 'url': 'https://example.com/comparatif-paiement', 'kind': 'document',
                            'summary': 'Frais, délais de versement et qualité des API.', 'labels': [LUMEN]})
call('POST', '/artifacts', {'title': 'Plan de tests de la 1.4', 'url': 'https://example.com/plan-de-tests', 'kind': 'document',
                            'summary': 'Scénarios à rejouer avant chaque mise en ligne.', 'labels': [BOREE]})

call('POST', '/mindmaps', {'title': 'Refonte de la boutique', 'labels': [LUMEN], 'children': [
    {'text': 'Catalogue', 'children': [{'text': 'Galerie plein écran', 'task_id': ids['Fiche produit : galerie plein écran']},
                                       {'text': 'Filtres couleur et matière'}, {'text': 'Images optimisées'}]},
    {'text': 'Commande', 'children': [{'text': 'Paiement en 3 fois', 'task_id': ids['Tunnel de commande : paiement en 3 fois']},
                                      {'text': 'Codes promo'}, {'text': 'Frais de port'}]},
    {'text': 'Livraison', 'children': [{'text': 'Nouvelle API transporteur'}, {'text': 'Suivi de colis'}]},
    {'text': 'Qualité', 'children': [{'text': 'Tests de bout en bout'}, {'text': 'Suivi des performances'}]},
]})

call('POST', '/clients', {'name': LUMEN, 'address': '12 rue des Verriers\n69000 Lyon', 'rate': 480, 'currency': 'EUR',
                          'projects': ['Lumen · Boutique', 'Lumen · Maintenance']})
call('POST', '/clients', {'name': BOREE, 'address': '4 quai du Nord\n44000 Nantes', 'rate': 520, 'currency': 'EUR', 'projects': ['Borée · App mobile']})
print(f'{len(tasks)} tâches, {len(entries)} entrées de temps, 3 notes, 3 artifacts, 1 carte mentale')
