class StatSender_Config : JsonApiStruct
{
	string Address;
	string Token;

	void CST_Config()
	{
		RegV("Address");
		RegV("Token");
	}
}