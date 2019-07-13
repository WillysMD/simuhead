from django.db import models


class ExternalFile(models.Model):
    name = models.TextField()
    version = models.TextField()

    class Meta:
        abstract = True


class Pak(ExternalFile):
    file = models.FileField(upload_to='paks')


class Save(ExternalFile):
    file = models.FileField(upload_to='saves')


class Instance(models.Model):
    name = models.TextField(unique=True)

    # Instance configuration
    port = models.IntegerField()
    revision = models.IntegerField()
    lang = models.CharField(max_length=2)

    pak = models.ForeignKey(Pak, on_delete=models.DO_NOTHING)
    save = models.ForeignKey(Save, on_delete=models.DO_NOTHING)
