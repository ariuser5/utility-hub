import os

llm_address = os.getenv("LOCAL_LLM_BASE_ADDRESS")

api_url = f'http://{llm_address}/api/chat/completions'
default_model = 'llama3.2:latest'
jwt = os.getenv("OPEN_WEBUI_JWT")