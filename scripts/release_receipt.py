"""Qualify an exact main CI run; emit no deployment credentials."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPOSITORY = 'donovan-yohan/open-music-player'


def qualify(run, prs, detail, sha):
    if not (re.fullmatch('[0-9a-f]{40}', sha)
            and run.get('status') == 'completed' and run.get('conclusion') == 'success'
            and run.get('event') == 'push' and run.get('head_branch') == 'main'
            and run.get('head_sha') == sha
            and run.get('path') == '.github/workflows/ci.yml'
            and run.get('repository', {}).get('full_name') == REPOSITORY):
        raise ValueError('exact main CI qualification failed')
    matches = [pr for pr in prs if pr.get('merged_at') and pr.get('merge_commit_sha') == sha
               and pr.get('base', {}).get('ref') == 'main'
               and pr.get('base', {}).get('repo', {}).get('full_name') == REPOSITORY]
    if len(matches) != 1 or not (detail.get('number') == matches[0]['number']
            and detail.get('merged') is True and detail.get('merge_commit_sha') == sha
            and detail.get('merged_by', {}).get('login') == REPOSITORY.split('/')[0]):
        raise ValueError('owner-merged PR required')
    return matches[0]['number']


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPOSITORY + '/' + path]))


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    sha = event['workflow_run']['head_sha']
    run = api('actions/runs/' + str(event['workflow_run']['id']))
    prs = api('commits/' + sha + '/pulls')
    matches = [p for p in prs if p.get('merged_at') and p.get('merge_commit_sha') == sha]
    if len(matches) != 1:
        raise ValueError('no unique merged PR')
    detail = api('pulls/' + str(matches[0]['number']))
    pr = qualify(run, prs, detail, sha)
    if api('git/ref/heads/main')['object']['sha'] != sha:
        raise ValueError('superseded main revision')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'sha={sha}\npr={pr}\ntree={api("git/commits/" + sha)["tree"]["sha"]}\n')
    print('Qualified owner-merged main PR', pr)


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, subprocess.CalledProcessError):
        print('Release qualification refused', file=sys.stderr)
        raise SystemExit(1)
