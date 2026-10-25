{{/*
Job manifests the watcher uses as templates. It fills in metadata.name, project labels and the
runner container's REPO_URL, RUNNER_* and REG_TOKEN env before creating each Job.
*/}}

{{- define "runner-watcher.runnerJobLabels" -}}
app.kubernetes.io/name: runner
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: runner
{{- end }}

{{- define "runner-watcher.runnerCacheEnv" -}}
{{- if .Values.cache.enabled }}
- name: CUSTOM_ACTIONS_RESULTS_URL
  value: {{ include "runner-watcher.cacheUrl" . | quote }}
{{- end }}
{{- end }}

{{- define "runner-watcher.linuxJob" -}}
{{- $runner := .Values.runners.linux -}}
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    {{- include "runner-watcher.runnerJobLabels" . | nindent 4 }}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: {{ .Values.runners.ttlSecondsAfterFinished }}
  template:
    metadata:
      labels:
        {{- include "runner-watcher.runnerJobLabels" . | nindent 8 }}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      initContainers:
        # Job containers mount the runner's externals (node etc.) via dockerd, so both need them at the same path.
        - name: externals
          image: {{ include "runner-watcher.image" $runner.image | quote }}
          imagePullPolicy: {{ $runner.image.pullPolicy }}
          command: ["cp", "-a", "/home/runner/externals/.", "/externals/"]
          volumeMounts:
            - name: externals
              mountPath: /externals
        # Native sidecar: starts before the runner and is stopped once the runner exits.
        - name: dind
          image: {{ include "runner-watcher.image" $runner.dind.image | quote }}
          imagePullPolicy: {{ $runner.dind.image.pullPolicy }}
          restartPolicy: Always
          args: ["dockerd", "--host=tcp://127.0.0.1:2375", "--tls=false"]
          env:
            - name: DOCKER_TLS_CERTDIR
              value: ""
          securityContext:
            privileged: true
          startupProbe:
            exec:
              command: ["docker", "-H", "tcp://127.0.0.1:2375", "info"]
            periodSeconds: 2
            failureThreshold: 60
          resources:
            {{- toYaml $runner.dind.resources | nindent 12 }}
          volumeMounts:
            - name: work
              mountPath: /home/runner/_work
            - name: externals
              mountPath: /home/runner/externals
            - name: docker-data
              mountPath: /var/lib/docker
      containers:
        - name: runner
          image: {{ include "runner-watcher.image" $runner.image | quote }}
          imagePullPolicy: {{ $runner.image.pullPolicy }}
          env:
            - name: DOCKER_HOST
              value: "tcp://127.0.0.1:2375"
            {{- include "runner-watcher.runnerCacheEnv" . | nindent 12 }}
          resources:
            {{- toYaml $runner.resources | nindent 12 }}
          volumeMounts:
            - name: work
              mountPath: /home/runner/_work
            - name: externals
              mountPath: /home/runner/externals
      volumes:
        - name: work
          emptyDir: {}
        - name: externals
          emptyDir: {}
        - name: docker-data
          emptyDir: {}
{{- end }}

{{- define "runner-watcher.windowsJob" -}}
{{- $runner := .Values.runners.windows -}}
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    {{- include "runner-watcher.runnerJobLabels" . | nindent 4 }}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: {{ .Values.runners.ttlSecondsAfterFinished }}
  template:
    metadata:
      labels:
        {{- include "runner-watcher.runnerJobLabels" . | nindent 8 }}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $runner.dockerDindSelector }}
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  {{- toYaml . | nindent 18 }}
              namespaceSelector: {}
              topologyKey: kubernetes.io/hostname
      {{- end }}
      containers:
        - name: runner
          image: {{ include "runner-watcher.image" $runner.image | quote }}
          imagePullPolicy: {{ $runner.image.pullPolicy }}
          env:
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: DOCKER_HOST
              value: {{ $runner.dockerHost | quote }}
            {{- include "runner-watcher.runnerCacheEnv" . | nindent 12 }}
          resources:
            {{- toYaml $runner.resources | nindent 12 }}
{{- end }}
