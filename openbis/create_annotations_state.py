#!/usr/bin/env python3
#
# Create internal property $ANNOTATIONS_STATE
#
# requires: pybis

from pybis import Openbis
import getpass
import os

dst = Openbis(url="http://localhost:8080", verify_certificates=False,
              allow_http_but_do_not_use_this_in_production_and_only_within_safe_networks=True)
# dst.login("admin", getpass.getpass(prompt=f"Password: "), save_token=False);
dst.login("admin", os.environ.get("OPENBIS_ADMIN_PASS").strip(), save_token=False)


def exec_svc(self, code, **kwargs):
    serviceCode = {
        "@type": "as.dto.service.id.CustomASServiceCode",
        "permId": code
    }
    options = {
        "@type": "as.dto.service.CustomASServiceExecutionOptions",
        "parameters": kwargs
    }
    request = {
        "method": "executeCustomASService",
        "params": [
            self.token,
            serviceCode,
            options
        ],
    }
    resp = self._post_request(self.as_v3, request)
    return resp


try:
    print(exec_svc(dst, "create-system-props",
                   prop={"code": "$ANNOTATIONS_STATE",
                         "label": "Annotations State",
                         "description": "Annotations State",
                         "dataType": "XML", }))
except ValueError as e:
    if not "exists" in str(e):
        raise
