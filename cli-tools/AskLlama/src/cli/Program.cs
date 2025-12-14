using Python.Runtime;

const string pythonDllPath = "PYTHON_DLL_PATH";
const string pythonVenvPath = "PYTHON_LOCAL_VENV";

// Initialize the Python engine
Runtime.PythonDLL = Environment.GetEnvironmentVariable(pythonDllPath, EnvironmentVariableTarget.User)
	?? throw new InvalidOperationException($"{pythonDllPath} environment variable is not set.");

PythonEngine.Initialize();

try
{
	string emailContent = ReadEmailContent();
	
	// Configure Python to use virtual environment packages and execute script
	using var _ = Py.GIL();
	dynamic sys = Py.Import("sys");

	var venvPath = Environment.GetEnvironmentVariable(pythonVenvPath, EnvironmentVariableTarget.User)
		?? throw new InvalidOperationException($"{pythonVenvPath} environment variable is not set.");

	var venvSitePackages = Path.Combine(venvPath, "Lib", "site-packages");
	sys.path.insert(0, venvSitePackages);

	Console.WriteLine("Python path configured for virtual environment");
	Console.WriteLine($"sys.path includes: {sys.path}");

	// Get the path to the script in the output directory
	var scriptsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "scripts");
	var fcScriptPath = Path.Combine(scriptsDir, "fc.py");

	if (!File.Exists(fcScriptPath))
	{
		Console.WriteLine($"Script not found: {fcScriptPath}");
		return;
	}

	sys.path.append(scriptsDir);

	// Import the fc module
	dynamic fc = Py.Import("fc");
	dynamic result = fc.is_task_email(emailContent);

	// Process the result
	Console.WriteLine($"Function called successfully. Response status: {result.status_code}");
	if (result.status_code == 200)
	{
		dynamic jsonResponse = result.json()["choices"][0]["message"]["content"];
		Console.WriteLine($"Response: {jsonResponse}");
	}
}
finally
{
	// In modern .NET, PythonEngine.Shutdown() may throw a PlatformNotSupportedException
	// due to BinaryFormatter removal. This is expected and can be safely ignored.
	try
	{
		PythonEngine.Shutdown();
	}
	catch (PlatformNotSupportedException ex)
	{
		Console.WriteLine($"[Warning] PythonEngine.Shutdown() failed: {ex.Message}");
	}
}

static string ReadEmailContent()
{
	Console.WriteLine("Enter the path to the email content file: ");
	
	const string emailContentFile = @"resources\email.txt";
	string emailContent = File.ReadAllText(emailContentFile);
	
	Console.WriteLine($"Email content read from {emailContentFile} with content:\n" +
		$"```\n" +
		$"{emailContent}" +
		$"\n```");

	return emailContent;
}
