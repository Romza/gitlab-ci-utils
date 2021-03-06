# Gitlab CI Utils

This repo contains image for Gitlab CI pipelines with some basic scripts I found useful.

### wait_for_other_pipelines_to_finish.sh

This is handy once you have detached pipelines in your merge request and you need to wait how other pipelines end up.

Usage example:

```yml
wait for all pipelines results:
  stage: wait
  image: beranm14/gitlab-ci-utils:latest
  script:
    - wait_for_other_pipelines_to_finish.sh
```

Required variable:

 * `SECRET_GITLAB_ACCESS_TOKEN` - token able to access gitlab api

### wait_for_runtime.sh

This script could be used once you have runner with concurrency larger than one and you need to wait for other pipelines
in the project to finish. Script waits until other pipelines finish and exit with zero to allow following job to
continue.

Usage example:

```yml
wait for runtime:
  stage: wait
  image: beranm14/gitlab-ci-utils:latest
  script:
    - wait_for_runtime.sh
```

Required variable:

 * `SECRET_GITLAB_ACCESS_TOKEN` - token able to access gitlab api

### cf_add_record.sh

This script register record to domain at CloudFlare by given variables.

Usage example:

```yml
add cf record:
  stage: wait
  image: beranm14/gitlab-ci-utils:latest
  script:
    - cf_add_record.sh
```

Required variable:

 * `DOMAIN_ZONE_ID` - CF zone id
 * `DOMAIN_KEY` - CF access token
 * `DOMAIN_EMAIL` - CF access email
 * `DOMAIN_CONTENT` - CF content of the report, e.g. `c.storage.googleapis.com`
 * `DOMAIN_NAME` - CF name of record, e.g. `myapp`
 
 Optional variable:

 * `DOMAIN_RECORD_TYPE` - default is `CNAME`

### cf_purge_by_url.sh

This script purges CloudFlare cache by given URL

Usage example:

```yml
clear cache by url:
  stage: wait
  image: beranm14/gitlab-ci-utils:latest
  script:
    - cf_purge_by_url.sh
```

Required variable:

 * `DOMAIN_ZONE_ID` - CF zone id
 * `DOMAIN_KEY` - CF access token
 * `DOMAIN_EMAIL` - CF access email
 * `PURGE_URL` - URL list to be purged from cache, each item should be separated by `,` and put into "", e.g.:
 `PURGE_URL='"https://example.com/index.html", "https://example.com/abc.js", "https://example.com/cba.js"'`


