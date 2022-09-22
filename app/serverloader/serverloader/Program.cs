using System;
using System.Collections;
using System.Diagnostics;
using System.Text;

var builder = WebApplication.CreateBuilder(args);
var memory = new List<string>();

// Add services to the container.
// Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();
var rand = new Random();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.MapGet("/workout", () =>
{
    // Generate a random string
    var randomString = GenerateRandomString(8192);

    // Bubble sort to do some work
   // var sortedString = BubbleSortString(randomString);

    // Store it in memory
    memory.Add(randomString);

    // Count all instances of all the letters
    for (char c = 'A'; c < 'Z'; c++)
    {
        CountOccuranceOf(c, randomString);
    }

    // Return it
    return randomString;
})
.WithName("GetWorkout");

app.MapGet("/stats", () =>
{
    var machineName = Environment.MachineName;
    var processorCount = Environment.ProcessorCount;
    var memoryWorkingSetBytes = Environment.WorkingSet;
    var totalStrings = memory.Count;
    
    return string.Format("Machine: {0} \nLogical processors: {1}\nStrings in memory: {2}\nMemory working set: {3} MB", machineName, processorCount, totalStrings, memoryWorkingSetBytes/1024/1024) ;
})
.WithName("GetStats");

app.MapGet("/healthz", () =>
{
    return "OK";
})
.WithName("GetHealthz");

app.Run();

string GenerateRandomString(int Length)
{
    var stringBuilder = new StringBuilder();
    char letter;
    for (int i = 0; i < Length; i++)
    {
        int randValue = rand.Next(0, 26);
        letter = Convert.ToChar(randValue + 65);
        stringBuilder.Append(letter);
    }

    return stringBuilder.ToString();
}

string BubbleSortString(string input)
{
    var inputArray = input.ToCharArray();
    char temp;

    for (int j = 0; j <= inputArray.Length - 2; j++)
    {
        for (int i = 0; i <= inputArray.Length - 2; i++)
        {
            if (inputArray[i].CompareTo(inputArray[i + 1]) > 0)
            {
                temp = inputArray[i + 1];
                inputArray[i + 1] = inputArray[i];
                inputArray[i] = temp;
            }
        }
    }

    return new string(inputArray);
}

int CountOccuranceOf(char lookFor, string input)
{
    int count = 0;
    for (int i = 0; i <= input.Length-1; i++)
    {
        if (input[i] == lookFor)
        {
            count++;
        }
    }

    return count;
}