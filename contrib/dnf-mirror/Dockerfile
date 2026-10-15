FROM registry.fedoraproject.org/fedora:43

RUN dnf -y install createrepo_c rpm-sign gnupg2 python3 && dnf clean all

COPY sync.py /usr/local/bin/sync.py

ENTRYPOINT ["python3", "/usr/local/bin/sync.py"]
