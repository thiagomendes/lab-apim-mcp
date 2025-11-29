import os
import msal
import requests
from fastmcp import FastMCP, Context

# Stateless Initialization:
# stateless_http=True: Does not maintain persistent connections.
# json_response=True: Uses standard HTTP request/response, ideal for APIM.
mcp = FastMCP("AzureStatelessOBO", stateless_http=True, json_response=True)

# Identity Configurations (Injected via Environment Variables)
TENANT_ID = os.getenv("AZURE_TENANT_ID")
CLIENT_ID = os.getenv("BACKEND_CLIENT_ID")
CLIENT_SECRET = os.getenv("BACKEND_CLIENT_SECRET")
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"

@mcp.tool()
async def echo_message(message: str) -> str:
    """
    Simple Tool: Echoes the message back.
    Useful for testing connectivity without authentication.
    """
    return f"Echo from Azure: {message}"

@mcp.tool()
async def get_my_profile_info(ctx: Context) -> str:
    """
    Secure Tool: Reads the user's profile information via Microsoft Graph.
    Demonstrates the OBO (On-Behalf-Of) flow.
    """

    # 1. Capture the Client Token (VS Code) forwarded by APIM
    # The token comes in the 'Authorization: Bearer eyJ...' header
    
    # Robust way to get the Request object from FastMCP Context
    req = ctx.request_context
    
    # Strategy 1: Check for standard ASGI scope (common in FastMCP/Starlette integrations)
    if hasattr(req, "scope") and isinstance(req.scope, dict) and "headers" in req.scope:
        # ASGI headers are a list of [bytes, bytes] tuples
        for k, v in req.scope["headers"]:
            if k.decode("latin1").lower() == "authorization":
                auth_header = v.decode("latin1")
                break
        else:
            auth_header = None

    # Strategy 2: Check for Starlette/FastAPI Request object wrapper
    elif hasattr(req, "request") and hasattr(req.request, "headers"):
        auth_header = req.request.headers.get("authorization")
        
    # Strategy 3: Check if 'req' itself is the Request object (has headers)
    elif hasattr(req, "headers"):
         auth_header = req.headers.get("authorization")

    else:
        # DEBUG: If all fails, return the object structure so we can fix it
        return f"Debug Error: Context object type: {type(req)}. Attributes: {dir(req)}"

    if not auth_header:
        return "Security Error: Authorization token not found in header."

    # Extract only the token hash
    user_token = auth_header.split(" ")[1]

    # 2. Execute OBO Flow (Token Exchange) in Entra ID
    # The App (Backend) uses its credentials + the user's token to request a token for Graph
    cca = msal.ConfidentialClientApplication(
        CLIENT_ID,
        authority=AUTHORITY,
        client_credential=CLIENT_SECRET
    )

    # Desired scope in the target resource (Graph)
    result = cca.acquire_token_on_behalf_of(
        user_assertion=user_token,
        scopes=["https://graph.microsoft.com/.default"]
    )

    if "access_token" not in result:
        error_desc = result.get('error_description', 'Unknown error')
        return f"OBO Authentication Failed: {error_desc}. Check Admin Consent in Portal."

    graph_token = result['access_token']

    # 3. Consume Downstream Resource (Microsoft Graph) with User Identity
    headers = {
        'Authorization': 'Bearer ' + graph_token,
        'Content-Type': 'application/json'
    }

    try:
        # Changed to /me (Profile) to guarantee success without Exchange License
        response = requests.get("https://graph.microsoft.com/v1.0/me", headers=headers)

        if response.status_code == 200:
            data = response.json()
            name = data.get('displayName', 'Unknown')
            email = data.get('userPrincipalName', 'Unknown')
            job = data.get('jobTitle', 'No Job Title')
            return f"Success! OBO Flow worked. User: {name} ({email}) - {job}"
        else:
            return f"Graph API Error: {response.status_code} - {response.text}"

    except Exception as e:
        return f"Exception connecting to Graph: {str(e)}"