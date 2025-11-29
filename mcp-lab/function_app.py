import azure.functions as func
from server import mcp

# Obtém o App ASGI do FastMCP
fastapi_app = mcp.http_app()

# Cria a Function App usando o wrapper oficial
# Não passamos 'route' (causa TypeError)
# Não chamamos .get() no app (causa AttributeError)
app = func.AsgiFunctionApp(app=fastapi_app, http_auth_level=func.AuthLevel.ANONYMOUS)
