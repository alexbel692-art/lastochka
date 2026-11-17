"""Выпуск в магазины — запускается в CI после публикации выпуска на GitHub (этап stores).

  python3 tool/store_publish.py play     — AAB в Google Play (дорожка PLAY_TRACK)
  python3 tool/store_publish.py appstore — сборку iPhone (уже выгружена в TestFlight этапом ios-appstore)
                                           на проверку Apple; после одобрения выходит сама

Без нужных секретов магазин пропускается с предупреждением — остальной выпуск это не задерживает.

Переменные: V (версия), BUILD (номер сборки = github.run_number), NOTES (что нового), BETA (true/false),
  Google Play: PLAY_SERVICE_ACCOUNT (JSON-ключ сервисного аккаунта), PLAY_TRACK, PLAY_BETA_TRACK, AAB (путь);
  App Store:   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

import jwt  # PyJWT[crypto]

PKG = 'app.lastochka.lastochka'  # и Android, и iPhone
V = os.environ.get('V', '')
BUILD = os.environ.get('BUILD', '')
BETA = os.environ.get('BETA', 'false') == 'true'
NOTES = os.environ.get('NOTES', '').strip() or 'Исправления и улучшения.'


def warn(msg):
    print(f'::warning::{msg}', flush=True)


def fail(msg):
    print(f'::error::{msg}', flush=True)
    sys.exit(1)


class HTTPFail(Exception):
    def __init__(self, code, body):
        super().__init__(f'HTTP {code}: {body[:3000]}')
        self.code, self.body = code, body


def call(method, url, token, body=None, data=None, ctype='application/json', timeout=120):
    if body is not None:
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'Bearer {token}')
    if data is not None:
        req.add_header('Content-Type', ctype)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise HTTPFail(e.code, e.read().decode('utf-8', 'replace'))


# ---------------- Google Play ----------------

def play():
    sa = os.environ.get('PLAY_SERVICE_ACCOUNT', '').strip()
    if not sa:
        warn('Google Play пропущен: нет секрета PLAY_SERVICE_ACCOUNT (см. docs/appstore/README.md)')
        return
    sa = json.loads(sa)
    now = int(time.time())
    assertion = jwt.encode({'iss': sa['client_email'], 'scope': 'https://www.googleapis.com/auth/androidpublisher',
                            'aud': sa['token_uri'], 'iat': now, 'exp': now + 3600}, sa['private_key'], algorithm='RS256')
    form = urllib.parse.urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion': assertion}).encode()
    with urllib.request.urlopen(urllib.request.Request(sa['token_uri'], data=form), timeout=60) as r:
        tok = json.loads(r.read())['access_token']

    track = os.environ.get('PLAY_BETA_TRACK' if BETA else 'PLAY_TRACK', '').strip() or ('beta' if BETA else 'production')
    base = f'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PKG}'
    edit = call('POST', f'{base}/edits', tok, {})['id']
    aab = open(os.environ['AAB'], 'rb').read()
    print(f'Google Play: загрузка {len(aab) // 1048576} МБ…', flush=True)
    up = call('POST', f'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PKG}/edits/{edit}/bundles?uploadType=media',
              tok, data=aab, ctype='application/octet-stream', timeout=1800)
    code = str(up['versionCode'])

    def set_track(status):
        call('PUT', f'{base}/edits/{edit}/tracks/{track}', tok, {'track': track, 'releases': [{
            'name': V, 'versionCodes': [code], 'status': status,
            'releaseNotes': [{'language': 'ru-RU', 'text': NOTES[:500]}]}]})

    set_track('completed')
    try:
        call('POST', f'{base}/edits/{edit}:commit', tok)
        print(f'::notice title=Google Play::{V} (код {code}) отправлена на дорожку «{track}» — выйдет после проверки Google')
    except HTTPFail as e:
        # приложение ещё ни разу не выпускалось: Google разрешает только черновик
        if 'draft' not in e.body.lower():
            raise
        set_track('draft')
        call('POST', f'{base}/edits/{edit}:commit', tok)
        warn(f'Google Play: {V} сохранена черновиком на дорожке «{track}» — приложение ещё не опубликовано, выпустите её в Play Console')


# ---------------- App Store ----------------

ASC = 'https://api.appstoreconnect.apple.com/v1'
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'}
IN_REVIEW = {'READY_FOR_REVIEW', 'WAITING_FOR_REVIEW', 'IN_REVIEW'}


def appstore():
    kid, iss, p8 = (os.environ.get(k, '').strip() for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'))
    if not (kid and iss and p8):
        warn('App Store пропущен: нет секретов ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 (см. docs/appstore/README.md)')
        return

    def token():
        now = int(time.time())
        return jwt.encode({'iss': iss, 'iat': now, 'exp': now + 1100, 'aud': 'appstoreconnect-v1'}, p8,
                          algorithm='ES256', headers={'kid': kid, 'typ': 'JWT'})

    def api(method, path, body=None):
        return call(method, path if path.startswith('http') else ASC + path, token(), body)

    def state(v):
        a = v['attributes']
        return a.get('appVersionState') or a.get('appStoreState')

    apps = api('GET', f'/apps?filter[bundleId]={PKG}')['data']
    if not apps:
        fail(f'App Store: в App Store Connect нет приложения {PKG} — создайте его (docs/appstore/README.md)')
    app = apps[0]['id']

    # 1. ждём, пока Apple обработает сборку (обычно 5–30 минут после выгрузки)
    q = urllib.parse.urlencode({'filter[app]': app, 'filter[version]': BUILD, 'filter[preReleaseVersion.version]': V})
    deadline = time.time() + 75 * 60
    while True:
        b = api('GET', f'/builds?{q}')['data']
        st = b[0]['attributes'].get('processingState') if b else None
        if st == 'VALID':
            build = b[0]['id']
            break
        if st in ('FAILED', 'INVALID'):
            fail(f'App Store: сборка {V} ({BUILD}) не прошла обработку Apple: {st} — подробности в письме от Apple')
        if time.time() > deadline:
            fail(f'App Store: сборка {V} ({BUILD}) не появилась за 75 минут (состояние: {st or "нет"})')
        print(f'App Store: ждём обработку сборки ({st or "ещё не видна"})…', flush=True)
        time.sleep(60)

    if BETA:
        print(f'::notice title=App Store::{V} — тестовая: доступна в TestFlight, на проверку не отправляется')
        return

    # 2. версия в App Store: та же, редактируемая или новая. Если прежняя ещё ждёт проверки — заменяем её:
    # новая сборка всё равно её вытеснит, а ждать две проверки подряд дольше
    versions = api('GET', f'/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=20')['data']
    open_subs = api('GET', f'/apps/{app}/reviewSubmissions?filter[platform]=IOS&filter[state]=WAITING_FOR_REVIEW,IN_REVIEW&limit=10')['data']
    for sub in open_subs:
        print(f'App Store: снимаем с проверки прежнюю отправку ({sub["attributes"].get("state")}) — её заменит {V}', flush=True)
        api('PATCH', f'/reviewSubmissions/{sub["id"]}', {'data': {'type': 'reviewSubmissions', 'id': sub['id'], 'attributes': {'canceled': True}}})
    if open_subs:
        for _ in range(30):  # снятие с проверки занимает от секунд до пары минут
            versions = api('GET', f'/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=20')['data']
            if not any(state(v) in IN_REVIEW for v in versions):
                break
            time.sleep(10)

    ver = next((v for v in versions if state(v) in EDITABLE), None)
    if ver:
        vid = ver['id']
        api('PATCH', f'/appStoreVersions/{vid}', {'data': {'type': 'appStoreVersions', 'id': vid,
                                                            'attributes': {'versionString': V, 'releaseType': 'AFTER_APPROVAL'}}})
    else:
        vid = api('POST', '/appStoreVersions', {'data': {'type': 'appStoreVersions',
            'attributes': {'platform': 'IOS', 'versionString': V, 'releaseType': 'AFTER_APPROVAL'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']['id']
    api('PATCH', f'/appStoreVersions/{vid}/relationships/build', {'data': {'type': 'builds', 'id': build}})

    # 3. «Что нового» (у самой первой версии этого поля нет — Apple вернёт ошибку, это нормально)
    for loc in api('GET', f'/appStoreVersions/{vid}/appStoreVersionLocalizations')['data']:
        try:
            api('PATCH', f'/appStoreVersionLocalizations/{loc["id"]}', {'data': {'type': 'appStoreVersionLocalizations',
                                                                            'id': loc['id'], 'attributes': {'whatsNew': NOTES[:4000]}}})
        except HTTPFail as e:
            print(f'App Store: «Что нового» ({loc["attributes"].get("locale")}) не записано: {e}', flush=True)

    # 4. на проверку
    subs = api('GET', f'/apps/{app}/reviewSubmissions?filter[platform]=IOS&filter[state]=READY_FOR_REVIEW&limit=1')['data']
    sid = subs[0]['id'] if subs else api('POST', '/reviewSubmissions', {'data': {'type': 'reviewSubmissions',
        'attributes': {'platform': 'IOS'}, 'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']['id']
    try:
        api('POST', '/reviewSubmissionItems', {'data': {'type': 'reviewSubmissionItems', 'relationships': {
            'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': sid}},
            'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}})
    except HTTPFail as e:
        if e.code != 409:  # 409 — версия уже в этой отправке
            raise
    try:
        api('PATCH', f'/reviewSubmissions/{sid}', {'data': {'type': 'reviewSubmissions', 'id': sid, 'attributes': {'submitted': True}}})
    except HTTPFail as e:
        fail(f'App Store: {V} не отправлена на проверку — в App Store Connect чего-то не хватает (скриншоты, описание, '
             f'анкеты)? Сборка уже прикреплена к версии, можно дозаполнить и нажать «Отправить» вручную. Ответ Apple: {e}')
    print(f'::notice title=App Store::{V} ({BUILD}) отправлена на проверку Apple — выйдет сама после одобрения')


if __name__ == '__main__':
    if not V or not BUILD:
        fail('нужны переменные V и BUILD')
    {'play': play, 'appstore': appstore}[sys.argv[1]]()
