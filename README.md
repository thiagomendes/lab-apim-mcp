# Lab Guide: Serverless MCP Server Implementation with Zero Trust Security (OBO)

This document details the step-by-step process to build, deploy, and consume an MCP (Model Context Protocol) Server hosted on a Serverless architecture in Azure. The goal is to validate a corporate security flow where the AI agent (Client) operates with the end-user's identity, propagating it to backend systems (Microsoft Graph) via the On-Behalf-Of (OBO) flow.

## 1. Laboratory Overview

### Solution Architecture

- **Client**: Visual Studio Code (simulating the Agent/Copilot).
- **Gateway**: Azure API Management (APIM) - Token validation and routing layer.
- **MCP Server**: Azure Functions (Python v2) - Stateless tool execution.
- **Identity**: Microsoft Entra ID - Identity provider and token issuer.
- **Target Resource**: Microsoft Graph API - Protected resource accessed on behalf of the user.

### Architecture Diagram

![Architecture Diagram](./apip-mcp-labl.svg)

The diagram above illustrates the complete flow:

1. **User** sends a prompt through **Visual Studio Code**
2. **VS Code** reads the token from `mcp.json` configuration
3. **VS Code** sends an MCP Request (JSON-RPC) with Bearer token to **Azure API Management**
4. **APIM** validates the token against **Microsoft Entra ID** using policy
5. **APIM** proxies the authenticated request to **Azure Functions**
6. **Azure Functions** requests token exchange (OBO) from **Entra ID**
7. **Entra ID** returns an access token for Microsoft Graph
8. **Azure Functions** calls **Microsoft Graph API** with the new token
9. **Microsoft Graph** returns the requested data (e.g., email subject)
10. **Azure Functions** returns the MCP tool response through **APIM** back to **VS Code**

## 2. Prerequisites

Ensure you have the following tools installed and configured:

- **Azure CLI** (`az`) logged into your subscription
- **Azure Functions Core Tools** (`func`)
- **Python 3.10+** and `pip`
- **Visual Studio Code** (with the "GitHub Copilot" extension active, if available, or ready for MCP configuration)

## 3. Phase 1: Infrastructure Provisioning (Azure CLI)

Run the commands below in your terminal (Bash/WSL) to create the base infrastructure. We use a random suffix to ensure unique names.

```bash
# --- Global Variables Configuration ---
RND=$RANDOM
GRP="rg-mcp-obo-lab-$RND"
LOC="eastus2"
STG="stmcplab$RND"
FUNC="func-mcp-api-$RND"
APIM="apim-mcp-gw-$RND"
EMAIL="admin@yourdomain.com" # Change to your real email

# 1. Create Resource Group
echo "Creating Resource Group: $GRP..."
az group create --name $GRP --location $LOC

# 2. Create Storage Account (Requirement for Azure Functions)
echo "Creating Storage Account..."
az storage account create --name $STG --location $LOC --resource-group $GRP --sku Standard_LRS

# 3. Create the Function App with Consumption Plan (Python 3.11)
# Note: For Linux consumption plan, we use --consumption-plan-location instead of creating a separate plan
# This automatically creates a serverless consumption plan (zero/low cost)
echo "Creating Function App with Consumption Plan: $FUNC..."
az functionapp create --name $FUNC --storage-account $STG --consumption-plan-location $LOC --resource-group $GRP --runtime python --runtime-version 3.11 --functions-version 4 --os-type Linux

# 4. Create API Management (Consumption Tier)
echo "Provisioning APIM (This may take a few minutes)..."
az apim create --name $APIM --resource-group $GRP --location $LOC --publisher-name "MCP Lab Admin" --publisher-email $EMAIL --sku-name Consumption
```

## 4. Phase 2: Identity Configuration (Microsoft Entra ID)

This step is critical for the OBO flow to work. We will create two identities: one for the Backend (API) and another for the Client (VS Code).

### 4.1 Backend Registration (Server)

```bash
# 1. Create Backend App Registration
echo "Registering Backend App..."
BACKEND_APP_ID=$(az ad app create --display-name "mcp-lab-backend-$RND" --sign-in-audience AzureADMyOrg --query appId -o tsv)

# 2. Create Service Principal for the App
az ad sp create --id $BACKEND_APP_ID

# 3. Generate Client Secret (Required for the Backend to perform OBO token exchange)
echo "Generating Client Secret..."
BACKEND_SECRET=$(az ad app credential reset --id $BACKEND_APP_ID --display-name "OBOSecret" --query password -o tsv)

# 4. Define API URI (App ID URI)
# This allows the app to expose scopes. Format: api://<client_id>
az ad app update --id $BACKEND_APP_ID --identifier-uris "api://$BACKEND_APP_ID"

# 5. Add Delegated Permission for Microsoft Graph (User.Read)
# Graph API ID: 00000003-0000-0000-c000-000000000000
# User.Read Role ID: e1fe6dd8-ba31-4d61-89e7-88639da4683d
az ad app permission add --id $BACKEND_APP_ID --api 00000003-0000-0000-c000-000000000000 --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope

# 6. Display Credentials (COPY THESE VALUES)
echo "------------------------------------------------"
echo "Backend Client ID: $BACKEND_APP_ID"
echo "Backend Client Secret: $BACKEND_SECRET"
echo "Tenant ID: $(az account show --query tenantId -o tsv)"
echo "------------------------------------------------"
```

### 4.2 Mandatory Manual Action (Azure Portal)

Due to limitations in automating consent via CLI for quick Labs:

1. Access the **Azure Portal** > **Microsoft Entra ID** > **App registrations**
2. Locate the app `mcp-lab-backend-<RND>`
3. Go to **Expose an API** > **+ Add a scope**
   - **Scope name**: `MCP.Execute`
   - **Who can consent**: Admins and users
   - Fill in the description fields with "Access to MCP" and Save
4. Go to **API Permissions**
5. Click the **Grant admin consent for <Your Organization>** button. This authorizes the backend to read the Graph profile without UI interaction (which does not exist in the MCP flow)

## 5. Phase 3: MCP Server Development (Python)

Create a local folder for the project and add the files below.

### 5.1 File Structure

```
mcp-lab/
├── function_app.py       # Azure Functions Entrypoint
├── server.py             # MCP Logic and Tools
├── requirements.txt      # Dependencies
└── host.json             # Runtime Configuration
```

### 5.2 requirements.txt

```
azure-functions
fastmcp
msal
requests
```

### 5.3 function_app.py

Integration of the FastMCP framework with the Azure Functions runtime via ASGI adapter.

```python
import azure.functions as func
from server import mcp

# Transforms the FastMCP server into an application compatible with Azure Functions
# json_response=True ensures compatibility with standard HTTP Trigger (Stateless)
fastapi_app = mcp.http_app()

app = func.AsgiFunctionApp(app=fastapi_app, http_auth_level=func.AuthLevel.ANONYMOUS)
```

### 5.4 server.py

Implementation of business logic and OBO security.

```python
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
async def get_my_latest_email(ctx: Context) -> str:
    """
    Secure Tool: Reads the subject of the user's latest email via Microsoft Graph.
    Demonstrates the OBO (On-Behalf-Of) flow.
    """

    # 1. Capture the Client Token (VS Code) forwarded by APIM
    # The token comes in the 'Authorization: Bearer eyJ...' header
    auth_header = ctx.request_context.headers.get("authorization")
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
        response = requests.get("https://graph.microsoft.com/v1.0/me/messages?$top=1", headers=headers)

        if response.status_code == 200:
            data = response.json()
            if data.get('value'):
                subject = data['value'][0].get('subject', 'No Subject')
                return f"Success! Subject of latest email: '{subject}'"
            return "You have no emails in your inbox."
        else:
            return f"Graph API Error: {response.status_code} - {response.text}"

    except Exception as e:
        return f"Exception connecting to Graph: {str(e)}"
```

### 5.5 Function Deployment

In the terminal, inside the project folder:

```bash
# 1. Configure Environment Variables in Azure
az functionapp config appsettings set --name $FUNC --resource-group $GRP --settings \
  AZURE_TENANT_ID=$(az account show --query tenantId -o tsv) \
  BACKEND_CLIENT_ID=$BACKEND_APP_ID \
  BACKEND_CLIENT_SECRET=$BACKEND_SECRET

# 2. Publish Code
func azure functionapp publish $FUNC
```

## 6. Phase 4: Gateway Configuration (APIM)

APIM will protect the Function, validating the token before invoking the Python code.

### 6.1 API Import

```bash
# Base URL of the Function (Adding /api as per Azure Functions standard)
FUNC_URL="https://$FUNC.azurewebsites.net/api"

# Create the API in APIM pointing to the Function
az apim api create --service-name $APIM --resource-group $GRP --api-id mcp-backend --path mcp --display-name "MCP Backend OBO" --service-url $FUNC_URL --protocols https
```

### 6.2 Security Policy (Inbound Policy)

This policy performs JWT validation and, crucially, forwards the token to the backend.

Create a local file named `policy.xml`.

Replace `{{TENANT_ID}}` and `{{BACKEND_APP_ID}}` with the values generated in Phase 2.

```xml
<policies>
    <inbound>
        <base />
        <cors allow-credentials="true">
            <allowed-origins>
                <origin>*</origin>
            </allowed-origins>
            <allowed-methods>
                <method>POST</method>
                <method>GET</method>
            </allowed-methods>
            <allowed-headers>
                <header>Authorization</header>
                <header>Content-Type</header>
            </allowed-headers>
        </cors>

        <validate-azure-ad-token tenant-id="{{TENANT_ID}}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Access Denied by Gateway: Invalid Token.">
            <client-application-ids>
            </client-application-ids>
            <audiences>
                <audience>api://{{BACKEND_APP_ID}}</audience>
            </audiences>
        </validate-azure-ad-token>

        <set-header name="Authorization" exists-action="override">
            <value>@(context.Request.Headers.GetValueOrDefault("Authorization"))</value>
        </set-header>
    </inbound>
    <backend>
        <base />
    </backend>
    <outbound>
        <base />
    </outbound>
</policies>
```

Apply the policy via CLI:

```bash
az apim api policy update --service-name $APIM --resource-group $GRP --api-id mcp-backend --xml-content @policy.xml
```

## 7. Phase 5: Client Configuration (VS Code)

Since VS Code does not yet have a native OAuth login flow for generic MCP servers, we will use manual token injection to validate the lab.

### 7.1 Obtain Valid Access Token

Generate a real token from your user with scope for the Backend.

```bash
# Ensure you are logged in with the user who has email/Office 365
az login

# Request the token for the resource (api://...)
# Copy the output of this command
az account get-access-token --resource "api://$BACKEND_APP_ID" --query accessToken -o tsv
```

### 7.2 Configure mcp.json in VS Code

At the root of your project in VS Code (folder `.vscode/mcp.json`):

```json
{
  "mcpServers": {
    "azure-obo-lab": {
      "url": "https://<YOUR_APIM_NAME>.azure-api.net/mcp",
      "type": "http",
      "headers": {
        "Authorization": "Bearer ${input:userToken}"
      }
    }
  },
  "inputs": {
    "userToken": {
        "type": "promptString",
        "description": "Paste the JWT Token obtained via Azure CLI here",
        "password": true
    }
  }
}
```

**Note**: Replace `<YOUR_APIM_NAME>` with the real name of the created APIM resource.

### 7.3 Final Test

1. Restart VS Code (**Developer: Reload Window**)
2. A dialog box will appear at the top requesting the token. Paste the token obtained in step 7.1
3. Open **GitHub Copilot Chat**
4. Type:

```
@azure-obo-lab What is the subject of my latest email?
```

**Expected Result:**

Copilot should respond with the actual subject of your last email, confirming that:

- VS Code sent the token to APIM
- APIM validated the token
- The Function received the token and exchanged it (OBO) for a Graph token
- Graph returned the user's personal data

## License

This project is for educational purposes demonstrating Azure serverless architecture with Zero Trust security patterns.
