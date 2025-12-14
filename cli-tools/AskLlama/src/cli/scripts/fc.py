import sys
import requests
from config import api_url, default_model, jwt

model = default_model

def is_task_email(email_content):
	headers = {
		'Authorization': f'Bearer {jwt}',
		'Content-Type': 'application/json'
	}
	schema = {
		"result": {
			"type": "boolean",
			"description": "True if the email contains a task, false otherwise."
		},
		"task_subject": {
			"type": "string",
			"description": "Then the subject of the task, if result is true."
		},
		"task_description": {
			"type": "string",
			"description": "A description of the task that the user needs to do, if result is true."
		}
	}
	payload = {
		"model": model,
		"messages": [
			{
				"role": "system",
				"content": (
					"You are a helpful AI assistant. The user will provide the content of an email "
					f"and you will respond according to the provided schema: {schema}."
				)
			},
			{
				"role": "user",
				"content": email_content
			},
		],
		"format": { 
			"type": "object",
			"properties": schema
		}, 
		"stream": False
	}
	response = requests.post(api_url, headers=headers, json=payload)
	return response
	

# result = is_task_email(email_content)
# msg = result.json()["choices"][0]["message"]["content"]
# print(msg, end="")