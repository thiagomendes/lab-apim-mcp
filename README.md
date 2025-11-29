# Journey: From Zero to Zero Trust with MCP and Azure APIM

This lab is designed as a story in **4 Acts**. You will start by deploying a simple MCP server in the cloud and evolve your architecture until you reach a complex enterprise scenario with identity validation and the On-Behalf-Of (OBO) flow.

## The Goal (Target State)

By the end of this journey, you will have a secure architecture where an AI Agent acts on behalf of the logged-in user to access sensitive data (Microsoft Graph), protected by an MCP Gateway.

![Architecture Diagram](./apip-mcp-labl.svg)

---

## The Scenario

You are a Platform Engineer tasked with making AI tools available to the company's developers.
1.  **Act 1:** Prove the concept works (Deploy).
2.  **Act 2:** Govern access to these tools (APIM MCP Gateway).
3.  **Act 3:** Secure the perimeter (Identity).
4.  **Act 4:** Ensure the AI accesses sensitive data using the user's own identity (OBO Flow).

---

## Prerequisites

- **Azure CLI** installed and logged in (`az login`).
- **Azure Functions Core Tools** (`func`).
- **Python 3.10+**.
- **Visual Studio Code** with the **GitHub Copilot** extension (or a compatible MCP client).

---

## Stage Preparation (Environment)

To ensure resource names are unique and reproducible, we will use a setup script.

1. Navigate to the lab folder:
   ```bash
   cd mcp-lab
   ```

2. Configure environment variables (run in your Bash/WSL terminal):
   ```bash
   source env-setup.sh
   ```
   *This command generates a random suffix and sets variables like `$GRP`, `$FUNC`, `$APIM`, `$AZURE_CLI_APP_ID` etc. Keep this terminal open throughout the lab.*

---

## 🎬 Act 1: The Birth of the MCP Server

In this phase, your goal is simple: get an MCP server running in the cloud (Azure Functions) and publicly accessible.

### 1.1 Provision Basic Infrastructure

```bash
# Create Resource Group
az group create --name $GRP --location $LOC

# Create Storage Account (Required for Functions)
az storage account create --name $STG --location $LOC --resource-group $GRP --sku Standard_LRS

# Create the Function App (Serverless Linux)
az functionapp create --name $FUNC --storage-account $STG --consumption-plan-location $LOC --resource-group $GRP --runtime python --runtime-version 3.11 --functions-version 4 --os-type Linux
```

### 1.2 Deploy the Code

The current code has a simple tool (`echo_message`) and a secure tool (`get_my_profile_info`). Let's publish it.

```bash
# Publish the Function App
func azure functionapp publish $FUNC
```

### 1.3 Smoke Test

Let's validate if the MCP server is alive by testing the simple tool.

1. In VS Code, edit the `.vscode/mcp.json` file (create it at the root of the project `lab-apim-mcp` if it doesn't exist):
   ```json
   {
     "mcpServers": {
       "azure-func-direct": {
         "url": "https://<YOUR_FUNCTION_NAME>.azurewebsites.net/mcp",
         "type": "http"
       }
     }
   }
   ```
   *(Replace `<YOUR_FUNCTION_NAME>` with the value of `$FUNC`. Run `echo $FUNC` in the terminal to see it).*

2. Restart VS Code or Reload the Window.
3. Open Copilot Chat and type:
   > `@azure-func-direct echo_message message="Hello Azure Function"`

**Success:** If Copilot responds "Echo from Azure: Hello Azure Function", Act 1 is complete.

---

## 🎬 Act 2: The Guardian (Azure MCP Gateway)

Accessing the Function directly is insecure and hard to manage. Let's put **Azure API Management (APIM)** in front to act as an Intelligent MCP Gateway.

### 2.1 Provision APIM

*Note: The "Developer" tier takes about 30-45 minutes to create. Good time for a coffee.*

```bash
az apim create --name $APIM --resource-group $GRP --location $LOC --publisher-name "Lab Admin" --publisher-email "admin@lab.com" --sku-name Developer
```

### 2.2 Import the MCP Server into APIM

APIM has native support for MCP servers (GenAI Gateway). We will do this via the Portal.

1. Go to the **Azure Portal** > **API Management** (`$APIM`).
2. In the left menu, select **MCP Servers**.
3. Click **+ Create** > **Connect an existing MCP server** (or just fill the form).
4. Fill in the form fields as follows:

   **Backend MCP server**
   *   **MCP server base url**: `https://<YOUR_FUNCTION_NAME>.azurewebsites.net/mcp`
       *(Replace `<YOUR_FUNCTION_NAME>` with `$FUNC`.*

   **New MCP server**
   *   **Display name**: `MCP Lab Gateway`
   *   **Name**: `mcp-lab`
   *   **Base path**: `lab`
   *   **Description**: `Azure Function acting as MCP Server`

5. Click **Create**.

### 2.3 Test via Gateway

Now let's point VS Code to APIM.

1. Update `.vscode/mcp.json`:
   ```json
   {
     "mcpServers": {
       "azure-apim-gw": {
         "url": "https://<YOUR_APIM_NAME>.azure-api.net/lab/mcp",
         "type": "http"
       }
     }
   }
   ```
2. Restart VS Code.
3. Test again:
   > `@azure-apim-gw echo_message message="Hello via APIM"`

**Success:** The flow is now: VS Code -> APIM -> Function.

---

## 🎬 Act 3: Identity & Security

Now let's lock the door. No one should call the APIM without a valid badge (JWT Token).

### 3.1 Create Application Identity (Backend)

We need to register our API in Microsoft Entra ID.

```bash
# Create App Registration
BACKEND_APP_ID=$(az ad app create --display-name "mcp-lab-backend-$RND" --sign-in-audience AzureADMyOrg --query appId -o tsv)

# Create Service Principal
az ad sp create --id $BACKEND_APP_ID

# Define API URI (api://<client_id>)
az ad app update --id $BACKEND_APP_ID --identifier-uris "api://$BACKEND_APP_ID"

# Expose "MCP.Execute" scope (Using Python for safe JSON generation)
python3 -c "import sys, uuid, json; scope_id = str(uuid.uuid4()); print(scope_id)" > scope_id.txt
SCOPE_ID=$(cat scope_id.txt) && rm scope_id.txt

python3 -c "import sys, json; scope_id = sys.argv[1]; data = {'oauth2PermissionScopes': [{'adminConsentDescription': 'Access MCP', 'adminConsentDisplayName': 'Access MCP', 'id': scope_id, 'isEnabled': True, 'type': 'User', 'userConsentDescription': 'Access MCP', 'userConsentDisplayName': 'Access MCP', 'value': 'MCP.Execute'}]}; print(json.dumps(data))" "$SCOPE_ID" > scope.json

az ad app update --id $BACKEND_APP_ID --set api=@scope.json
rm scope.json

echo "Backend App ID: $BACKEND_APP_ID"
```

### 3.2 Apply Policy in APIM (Validate JWT)

Let's configure APIM to reject calls without a token.

1. In the Portal, go to **MCP Servers** > Click on **MCP Lab Gateway**.
2. Look for the **Policies** option (or the `</>` icon in **Inbound processing**).
3. Insert the validation policy in the `<inbound>` block:

```xml
<inbound>
    <base />
    <!-- Allow CORS (No credentials/wildcard compatible) -->
    <cors>
        <allowed-origins><origin>*</origin></allowed-origins>
        <allowed-methods><method>*</method></allowed-methods>
        <allowed-headers><header>*</header></allowed-headers>
    </cors>

    <!-- Validate Entra ID Token -->
    <validate-azure-ad-token tenant-id="{{YOUR_TENANT_ID}}" header-name="Authorization">
        <audiences>
            <audience>api://{{YOUR_BACKEND_APP_ID}}</audience>
        </audiences>
    </validate-azure-ad-token>
</inbound>
```
*(Replace `{{YOUR_TENANT_ID}}` and `{{YOUR_BACKEND_APP_ID}}` with real values).*

### 3.3 Security Test (Expected Failure)

Try using `@azure-apim-gw echo_message` again in VS Code.

**Expected Result:** You will receive an **HTTP 401 Unauthorized** error immediately. This means the APIM policy is working!

---

## 🎬 Act 4: The On-Behalf-Of (OBO) Flow

The "Grand Finale". We will make VS Code send a token, APIM validate it, and the Function exchange this token for another to read your Profile.

### 4.1 Configure Secrets and Permissions

The Function needs permission to "speak on behalf of the user" (OBO).

```bash
# 1. Generate Secret for the App
BACKEND_SECRET=$(az ad app credential reset --id $BACKEND_APP_ID --display-name "OBOSecret" --query password -o tsv)

# 2. Grant Graph permission (User.Read) using Global IDs
MS_GRAPH_ID="00000003-0000-0000-c000-000000000000" # Microsoft Graph API
USER_READ_ID="e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read Scope

az ad app permission add --id $BACKEND_APP_ID --api $MS_GRAPH_ID --api-permissions $USER_READ_ID=Scope
az ad app permission grant --id $BACKEND_APP_ID --api $MS_GRAPH_ID --scope User.Read
```

### 4.2 Configure the Function App

Send the credentials to the Function in the cloud.

```bash
az functionapp config appsettings set --name $FUNC --resource-group $GRP --settings "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)" "BACKEND_CLIENT_ID=$BACKEND_APP_ID" "BACKEND_CLIENT_SECRET=$BACKEND_SECRET"
```

### 4.3 Configure the Client (VS Code)

We need a real token.

1. **Pre-authorization:** Allow Azure CLI to request tokens for your API. We use `az rest` to be robust against CLI schema changes.

   ```bash
   # 1. Get Object ID
   BACKEND_OBJ_ID=$(az ad app show --id $BACKEND_APP_ID --query id -o tsv)

   # 2. Generate JSON Config (Python one-liner for safe copy-paste)
   python3 -c "import sys, json; scope_id = sys.argv[1]; cli_id = sys.argv[2]; data = {'api': {'oauth2PermissionScopes': [{'adminConsentDescription': 'Access MCP', 'adminConsentDisplayName': 'Access MCP', 'id': scope_id, 'isEnabled': True, 'type': 'User', 'userConsentDescription': 'Access MCP', 'userConsentDisplayName': 'Access MCP', 'value': 'MCP.Execute'}], 'preAuthorizedApplications': [{'appId': cli_id, 'delegatedPermissionIds': [scope_id]}]}}; print(json.dumps(data))" "$SCOPE_ID" "$AZURE_CLI_APP_ID" > patch.json

   # 3. Apply via Graph API
   az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$BACKEND_OBJ_ID" --headers "Content-Type=application/json" --body @patch.json
   rm patch.json
   ```

2. **Generate Token:**
   ```bash
   # Login (Refreshes session)
   az login --tenant $(az account show --query tenantId -o tsv)
   
   # Get Token
   az account get-access-token --resource "api://$BACKEND_APP_ID" --query accessToken -o tsv
   ```
   *Copy the generated token.*

3. **Configure MCP Client:**
   Update `.vscode/mcp.json` to include your token **directly**.
   *(Note: We paste the token here because some VS Code extensions do not yet support interactive input prompts.)*

   ```json
   {
     "mcpServers": {
       "azure-obo-final": {
         "url": "https://<YOUR_APIM_NAME>.azure-api.net/lab/mcp",
         "type": "http",
         "headers": {
           "Authorization": "Bearer YOUR_LONG_TOKEN_HERE"
         }
       }
     }
   }
   ```

### 4.4 The Final Test

1. Reload the VS Code window.
2. Open Copilot Chat and call the secure tool:
   > `@azure-obo-final get_my_profile_info`

**Expected Result:**
The tool should respond with **"Success! OBO Flow worked"**, displaying your Name and Job Title retrieved securely from Microsoft Graph.

---
**Congratulations!** You have completed the journey.

### Cleanup
*Don't forget to delete all resources created during this lab to avoid ongoing costs.*
```bash
az group delete --name $GRP --yes --no-wait
```
