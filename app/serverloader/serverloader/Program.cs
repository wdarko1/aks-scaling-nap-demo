using System;
using System.Collections;
using System.Diagnostics;
using System.Text;
using Prometheus;

var builder = WebApplication.CreateBuilder(args);
var memory = new List<long>();

// Add services to the container.
// Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();
var rand = new Random();

// Configure the HTTP request pipeline.
app.UseSwagger();
app.UseSwaggerUI();

// Start the Prometheus metrics exporter to expose at /metrics
app.UseMetricServer();
app.UseHttpMetrics(options=>
{
    options.AddCustomLabel("host", context => context.Request.Host.Host);
});

app.MapGet("/", () =>
{
    return "App is up";
});

app.MapGet("/workout", () =>
{
    long nthPrime = FindPrimeNumber(1000);
    memory.Add(nthPrime);
    
    // Garbage collect every once in a while when the number of items in the memory grows to limitInMB
    if(Environment.WorkingSet/1024/1024 >= 110)
    {
        memory.Clear();
        GC.Collect();
    }

    // Return it
    return nthPrime;
})
.WithName("GetWorkout");

app.MapGet("/stats", () =>
{
    var machineName = Environment.MachineName;
    var processorCount = Environment.ProcessorCount;
    var memoryWorkingSetBytes = Environment.WorkingSet;
    var totalPrimes = memory.Count;
    
    return string.Format("Machine: {0} \nLogical processors: {1}\nPrimes in memory: {2}\nMemory working set: {3} MB", machineName, processorCount, totalPrimes, memoryWorkingSetBytes/1024/1024) ;
})
.WithName("GetStats");

app.MapGet("/healthz", () =>
{
    return "OK";
})
.WithName("GetHealthz");

app.Run();

long FindPrimeNumber(int n)
{
    int count=0;
    long a = 2;
    while(count<n)
    {
        long b = 2;
        int prime = 1;// to check if found a prime
        while(b * b <= a)
        {
            if(a % b == 0)
            {
                prime = 0;
                break;
            }
            b++;
        }
        if(prime > 0)
        {
            count++;
        }
        a++;
    }
    return (--a);
}