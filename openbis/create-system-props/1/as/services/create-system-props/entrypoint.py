from ch.ethz.sis.openbis.generic.asapi.v3.dto.space.create import SpaceCreation
from ch.ethz.sis.openbis.generic.asapi.v3.dto.property.create import PropertyTypeCreation
from ch.ethz.sis.openbis.generic.asapi.v3.dto.property import DataType

datatypes = dict(
    XML=DataType.XML,
    VARCHAR=DataType.VARCHAR
)

def process(context, parameters):
    res = []
    system_session_token = context.applicationService.loginAsSystem()
    try:
        res.append(system_session_token)
#        space_code = parameters.get('space_code')
#        if space_code:
#            space_creation = SpaceCreation()
#            space_creation.code = space_code
#            result = context.applicationService.createSpaces(
#                    #context.sessionToken,
#                    system_session_token,
#                    [space_creation]);
#            res.append("Space created: %s" % result)
        prop = parameters.get('prop')
        if prop:
            prop_creation = PropertyTypeCreation()
            prop_creation.code = prop["code"]
            prop_creation.dataType = datatypes[prop["dataType"]]
            prop_creation.managedInternally = (prop_creation.code.strip()[0] == "$")
            prop_creation.label = prop["label"]
            prop_creation.description = prop["description"]
            result = context.applicationService.createPropertyTypes(
                    #context.sessionToken,
                    system_session_token,
                    [prop_creation]);
            res.append("Property type created: %s" % result)
        return "\n".join(res)
    finally:
        # Logout the system session
        if system_session_token:
            context.applicationService.logout(system_session_token)
